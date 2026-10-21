defmodule Partyline.Client do
  @moduledoc """
  One Partyline client session: a `:gen_statem` that owns one link to a
  server, tracks the server's rooms and members, and reports everything
  to a subscriber process.

  ## States

      :resolving       waiting for a path to the server (request_path in a task)
      :connecting      link requested, waiting for :established
      :waiting_welcome HELLO sent, waiting for WELCOME
      :connected       WELCOME received; channel and user sync follows

  The session stops when the link closes. A terminal DENIED (room id
  nil: version mismatch, ban, allow list, wrong server password, kick)
  sets `kicked?` in the final `{:closed, reason}` event, as a hint to
  front ends not to reconnect.

  ## Events

  The subscriber receives `{:partyline, client_pid, event}`:

      {:connected, %{name: name, motd: motd, sid: sid, app: app}}
      {:version, server_app}               # server app version differs from ours
      {:channel, %Channel{}}
      {:channel_gone, %Channel{}}
      {:user_joined, %User{}}
      {:user_moved, %User{}, previous_room}
      {:user_state, %User{}, %User{} = previous}
      {:user_left, %User{}}
      :synced
      {:room, %Assignment{} | nil}
      {:denied, room_id | nil, reason}
      {:notice, text}
      {:text, %User{} | nil, member_id, text}
      {:poke, %User{} | nil, member_id, text}
      {:motd, text}
      {:room_spec, room_id, spec_map}
      {:call_waiting, identity_hex}
      {:call_done, identity_hex, event}
      {:frames, speaker_id, [binary | nil], seq | nil}
      {:talk_end, member_id}
      {:malformed, field, value}
      {:closed, %{reason: term(), error: String.t() | nil, kicked?: boolean()}}

  Audio frames are passed through as received; decoding, reordering and
  playout belong to the audio pipeline, not the session.
  """

  @behaviour :gen_statem

  require Logger

  alias Partyline.{Protocol, Transport}
  alias Partyline.Protocol.{Assignment, Channel, Hello, Text, User, Welcome}

  @welcome_timeout 10_000
  @path_wait 20_000

  defstruct [
    :adapter,
    :destination_hash,
    :identity,
    :name,
    :subscriber,
    :link,
    :info,
    :want_room,
    :want_password,
    :server_password,
    :path_task,
    :server_name,
    :server_app,
    :my_sid,
    :error,
    welcome_timeout: @welcome_timeout,
    text_only: false,
    muted: false,
    deaf: false,
    motd: "",
    my_room: nil,
    assignment: nil,
    synced: false,
    kicked: false,
    channels: %{},
    users: %{},
    pending_calls: %{}
  ]

  # ==========================================================================
  # API
  # ==========================================================================

  @doc """
  Start a session. Required: `:destination_hash`, `:name`.

  Options:
    * `:adapter` - transport adapter (default `Partyline.Transport.RNS`)
    * `:identity` - identity to identify with; nil connects anonymously
    * `:subscriber` - event recipient (default: caller)
    * `:room` - room id or name to join (default: server default room)
    * `:password` - room password
    * `:server_password` - server password
    * `:text_only`, `:muted`, `:deaf` - initial state (text_only implies both)
    * `:path_timeout` - ms to wait for a path (default 20 s)
    * `:welcome_timeout` - minimum ms to wait for WELCOME after HELLO
      (default 10 s; stretched to 15 x RTT on slow links)
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :subscriber, self())
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Ask to move to another room."
  def move(pid, room_id, password \\ nil), do: call_connected(pid, {:move, room_id, password})

  @doc "Send chat text to the current room."
  def send_text(pid, text), do: :gen_statem.call(pid, {:send_text, text})

  def poke(pid, member_id, text \\ "poke"), do: call_connected(pid, {:poke, member_id, text})

  @doc "Report local mute/deafen state."
  def set_state(pid, muted, deaf), do: :gen_statem.call(pid, {:set_state, muted, deaf})

  @doc "Operator action: kick, ban, mute, unmute, op, deop, move."
  def admin(pid, action, member_id, argument \\ nil)
      when action in ~w(kick ban mute unmute op deop move),
      do: call_connected(pid, {:admin, action, member_id, argument})

  def dialin(pid, action, argument \\ nil) when action in ~w(answer reject add remove list),
    do: call_connected(pid, {:dialin, action, argument})

  @doc """
  Operator server configuration. Payloads larger than one packet need a
  Resource transfer, which the transport doesn't support yet.
  """
  def configure(pid, action, payload \\ nil)
      when action in ~w(motd room_get room_add room_edit room_remove),
      do: :gen_statem.call(pid, {:configure, action, payload})

  @doc "Send audio frames (wire frames, codec byte included) with a base sequence number."
  def send_frames(pid, frames, seq), do: :gen_statem.call(pid, {:send_frames, frames, seq})

  @doc "End of a talk spurt (push-to-talk release or VOX close)."
  def talk_end(pid), do: :gen_statem.call(pid, :talk_end)

  @doc "Current session view."
  def info(pid), do: :gen_statem.call(pid, :info)

  @doc """
  Tear the link down and stop. The subscriber gets
  `{:closed, %{reason: :local, ...}}` like any other close.
  """
  def disconnect(pid), do: :gen_statem.call(pid, :disconnect)

  # Send a message that needs a connected session; {:error, :not_connected}
  # otherwise.
  defp call_connected(pid, message), do: :gen_statem.call(pid, {:send, message})

  # ==========================================================================
  # gen_statem
  # ==========================================================================

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    text_only = Keyword.get(opts, :text_only, false)

    data = %__MODULE__{
      adapter: Keyword.get(opts, :adapter, Partyline.Transport.RNS),
      destination_hash: Keyword.fetch!(opts, :destination_hash),
      identity: Keyword.get(opts, :identity),
      name: Keyword.fetch!(opts, :name),
      subscriber: Keyword.fetch!(opts, :subscriber),
      want_room: Keyword.get(opts, :room),
      want_password: Keyword.get(opts, :password),
      server_password: Keyword.get(opts, :server_password),
      text_only: text_only,
      muted: text_only or Keyword.get(opts, :muted, false),
      deaf: text_only or Keyword.get(opts, :deaf, false),
      welcome_timeout: Keyword.get(opts, :welcome_timeout, @welcome_timeout)
    }

    adapter = data.adapter
    hash = data.destination_hash
    timeout = Keyword.get(opts, :path_timeout, @path_wait)
    task = Task.async(fn -> Transport.request_path(adapter, hash, timeout) end)

    {:ok, :resolving, %{data | path_task: task}}
  end

  # --- :resolving ---------------------------------------------------------

  def resolving(:enter, _old, _data), do: :keep_state_and_data

  def resolving(:info, {ref, result}, %{path_task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    data = %{data | path_task: nil}

    with :ok <- result,
         {:ok, link} <-
           Transport.open_link(data.adapter, data.destination_hash, identity: data.identity) do
      {:next_state, :connecting, %{data | link: link}}
    else
      {:error, reason} -> fail(data, "no path to server: #{inspect(reason)}", {:no_path, reason})
    end
  end

  def resolving(:info, {:DOWN, ref, :process, _, reason}, %{path_task: %Task{ref: ref}} = data) do
    fail(%{data | path_task: nil}, "path request failed", {:path_task, reason})
  end

  def resolving(event_type, event, data), do: common(event_type, event, data)

  # --- :connecting --------------------------------------------------------

  def connecting(:enter, _old, _data), do: :keep_state_and_data

  def connecting(:info, {:partyline_transport, link, {:established, info}}, %{link: link} = data) do
    data = %{data | info: info}
    send_now(data, {:hello, hello(data)})
    {:next_state, :waiting_welcome, data}
  end

  def connecting(event_type, event, data), do: common(event_type, event, data)

  # --- :waiting_welcome ---------------------------------------------------

  def waiting_welcome(:enter, _old, data) do
    rtt_ms = trunc((data.info[:rtt] || 0) * 1_000)
    {:keep_state_and_data, [{:state_timeout, max(data.welcome_timeout, 15 * rtt_ms), :welcome}]}
  end

  def waiting_welcome(:state_timeout, :welcome, data) do
    Transport.close_link(data.link)
    fail(data, "server did not answer (not a room server, or an older version)", :welcome_timeout)
  end

  def waiting_welcome(event_type, event, data), do: common(event_type, event, data)

  # --- :connected ---------------------------------------------------------

  def connected(:enter, _old, _data), do: :keep_state_and_data

  def connected({:call, from}, {:send, message}, data) do
    {:keep_state_and_data, [{:reply, from, send_now(data, outgoing(message))}]}
  end

  def connected({:call, from}, {:send_text, text}, data) do
    case Text.clean(text, Text.max_text()) do
      "" -> {:keep_state_and_data, [{:reply, from, {:error, :empty}}]}
      _ when data.my_room == nil -> {:keep_state_and_data, [{:reply, from, {:error, :no_room}}]}
      cleaned -> {:keep_state_and_data, [{:reply, from, send_now(data, {:text, cleaned})}]}
    end
  end

  def connected({:call, from}, {:configure, action, payload}, data) do
    packet = Protocol.encode_to_server({:config, action, payload})

    reply =
      if byte_size(packet) > data.info.mdu,
        do: {:error, :needs_resource},
        else: Transport.send_packet(data.link, packet)

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def connected({:call, from}, {:send_frames, frames, seq}, data) do
    {:keep_state_and_data, [{:reply, from, send_now(data, {:frames, frames, seq})}]}
  end

  def connected({:call, from}, :talk_end, data) do
    {:keep_state_and_data, [{:reply, from, send_now(data, :talk_end)}]}
  end

  def connected(event_type, event, data), do: common(event_type, event, data)

  # --- shared -------------------------------------------------------------

  # Mute/deafen are local state before connecting and sent once connected,
  # as the reference stores them for HELLO.
  defp common({:call, from}, {:set_state, muted, deaf}, data) do
    data = %{data | muted: muted == true, deaf: deaf == true}

    reply =
      if data.my_sid != nil, do: send_now(data, {:state, data.muted, data.deaf}), else: :ok

    {:keep_state, data, [{:reply, from, reply}]}
  end

  defp common({:call, from}, :info, data) do
    {:keep_state_and_data, [{:reply, from, view(data)}]}
  end

  defp common({:call, from}, :disconnect, data) do
    if data.link, do: Transport.close_link(data.link)
    emit(data, {:closed, %{reason: :local, error: data.error, kicked?: data.kicked}})
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  defp common({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp common(:info, {:partyline_transport, link, {:packet, packet}}, %{link: link} = data) do
    case Protocol.decode_from_server(packet) do
      {:ok, messages} ->
        apply_messages(messages, data)

      {:error, reason} ->
        Logger.debug("[Partyline.Client] undecodable packet: #{inspect(reason)}")
        :keep_state_and_data
    end
  end

  defp common(:info, {:partyline_transport, link, {:closed, reason}}, %{link: link} = data) do
    emit(data, {:closed, %{reason: reason, error: data.error, kicked?: data.kicked}})
    {:stop, :normal, data}
  end

  defp common(:info, _msg, _data), do: :keep_state_and_data

  # ==========================================================================
  # Incoming messages
  # ==========================================================================

  # Apply a packet's messages in order. A WELCOME anywhere in the packet
  # moves the session to :connected once the whole packet is applied.
  defp apply_messages(messages, data) do
    result =
      Enum.reduce_while(messages, {:keep, data}, fn message, {transition, data} ->
        case apply_message(message, data) do
          {:ok, data} -> {:cont, {transition, data}}
          {:connected, data} -> {:cont, {:connected, data}}
          {:stop, data} -> {:halt, {:stop, data}}
        end
      end)

    case result do
      {:keep, data} -> {:keep_state, data}
      {:connected, data} -> {:next_state, :connected, data}
      {:stop, data} -> {:stop, :normal, data}
    end
  end

  defp apply_message({:welcome, %Welcome{} = w}, data) do
    if w.ver != Partyline.protocol_version() do
      advice =
        if is_integer(w.ver) and w.ver < Partyline.protocol_version(),
          do: "the server needs updating",
          else: "please update"

      message =
        "this server speaks Partyline protocol #{inspect(w.ver)}, " <>
          "this client speaks #{Partyline.protocol_version()}: #{advice}"

      Transport.close_link(data.link)
      data = %{data | kicked: true, error: message}
      emit(data, {:closed, %{reason: :protocol_version, error: message, kicked?: true}})
      {:stop, data}
    else
      data = %{data | server_name: w.name, my_sid: w.sid, motd: w.motd, server_app: w.app}
      emit(data, {:connected, %{name: w.name, motd: w.motd, sid: w.sid, app: w.app}})

      if w.app != Partyline.reference_app_version() do
        emit(data, {:version, w.app})
      end

      {:connected, data}
    end
  end

  defp apply_message({:channels, channels}, data) do
    data =
      Enum.reduce(channels, data, fn %Channel{} = channel, data ->
        emit(data, {:channel, channel})
        put_in(data.channels[channel.id], channel)
      end)

    {:ok, data}
  end

  defp apply_message({:users, users}, data), do: {:ok, Enum.reduce(users, data, &apply_user/2)}

  defp apply_message({:user_left, id}, data) do
    {user, users} = Map.pop(data.users, id)
    if user, do: emit(data, {:user_left, user})
    {:ok, %{data | users: users}}
  end

  defp apply_message(:synced, data) do
    emit(data, :synced)
    {:ok, %{data | synced: true}}
  end

  defp apply_message({:room, :none}, data) do
    emit(data, {:room, nil})
    {:ok, %{data | my_room: nil, assignment: nil}}
  end

  defp apply_message({:room, %Assignment{} = a}, data) do
    emit(data, {:room, a})
    {:ok, %{data | my_room: a.room_id, assignment: a}}
  end

  defp apply_message({:denied, room_id, reason}, data) do
    emit(data, {:denied, room_id, reason})

    # Room id nil: refused outright. The server is closing the link and
    # retrying won't help.
    if room_id == nil do
      {:ok, %{data | kicked: true, error: reason}}
    else
      {:ok, data}
    end
  end

  defp apply_message({:notice, text}, data), do: emit_ok(data, {:notice, text})

  defp apply_message({:text, member_id, text}, data),
    do: emit_ok(data, {:text, data.users[member_id], member_id, text})

  defp apply_message({:poke, member_id, text}, data),
    do: emit_ok(data, {:poke, data.users[member_id], member_id, text})

  defp apply_message({:dialin, "waiting", hex}, data) do
    emit(data, {:call_waiting, hex})
    {:ok, put_in(data.pending_calls[hex], System.monotonic_time(:millisecond))}
  end

  defp apply_message({:dialin, event, hex}, data) do
    case Map.pop(data.pending_calls, hex) do
      {nil, _} ->
        {:ok, data}

      {_, pending} ->
        emit(data, {:call_done, hex, event})
        {:ok, %{data | pending_calls: pending}}
    end
  end

  defp apply_message({:config, ["motd", motd | _]}, data) do
    motd = Text.clean(motd, Text.max_text())
    emit(data, {:motd, motd})
    {:ok, %{data | motd: motd}}
  end

  defp apply_message({:config, ["room", room_id, spec | _]}, data)
       when is_integer(room_id) and is_map(spec),
       do: emit_ok(data, {:room_spec, room_id, spec})

  defp apply_message({:config, _record}, data), do: {:ok, data}

  defp apply_message({:channel_gone, id}, data) do
    {channel, channels} = Map.pop(data.channels, id)
    if channel, do: emit(data, {:channel_gone, channel})
    {:ok, %{data | channels: channels}}
  end

  defp apply_message({:talk_end, member_id}, data), do: emit_ok(data, {:talk_end, member_id})

  defp apply_message({:frames, speaker, frames, seq}, data),
    do: emit_ok(data, {:frames, speaker, frames, seq})

  defp apply_message({:malformed, _field, _value} = m, data), do: emit_ok(data, m)

  defp apply_user(%User{} = user, data) do
    case data.users[user.id] do
      nil ->
        emit(data, {:user_joined, user})

      %User{room: room} = previous when room != user.room ->
        emit(data, {:user_moved, user, previous.room})

      previous ->
        emit(data, {:user_state, user, previous})
    end

    put_in(data.users[user.id], user)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp hello(data) do
    %Hello{
      name: data.name,
      room: data.want_room,
      password: data.want_password,
      server_password: data.server_password,
      text_only: data.text_only,
      muted: data.muted,
      deaf: data.deaf,
      hops: data.info[:hops],
      rtt: data.info[:rtt] && trunc(data.info.rtt * 1_000),
      ver: Partyline.protocol_version(),
      app: Partyline.reference_app_version()
    }
  end

  defp outgoing({:poke, id, text}), do: {:poke, id, Text.clean(text, Text.max_text(), "poke")}
  defp outgoing(message), do: message

  defp send_now(data, message) do
    Transport.send_packet(data.link, Protocol.encode_to_server(message))
  end

  defp emit(data, event), do: send(data.subscriber, {:partyline, self(), event})

  defp emit_ok(data, event) do
    emit(data, event)
    {:ok, data}
  end

  defp fail(data, message, reason) do
    emit(data, {:closed, %{reason: reason, error: message, kicked?: false}})
    {:stop, :normal, %{data | error: message}}
  end

  defp view(data) do
    %{
      server_name: data.server_name,
      server_app: data.server_app,
      motd: data.motd,
      sid: data.my_sid,
      room: data.my_room,
      assignment: data.assignment,
      synced: data.synced,
      channels: data.channels,
      users: data.users,
      muted: data.muted,
      deaf: data.deaf,
      mdu: data.info && data.info.mdu
    }
  end
end
