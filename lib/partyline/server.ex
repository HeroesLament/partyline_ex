defmodule Partyline.Server do
  @moduledoc """
  A Partyline room server, wire compatible with partyline 1.0.5
  `partyline-server`.

  One process owns the listener and every member link, like the
  reference server's single packet worker, so membership changes and
  relays are applied in one order.

  ## Options

    * `:identity` (required) - server identity (`RNS.Identity` record or
      stored hash for the RNS adapter; a 16-byte hash for Loopback)
    * `:adapter` - transport adapter (default `Partyline.Transport.RNS`)
    * `:register` - name to register the process under
    * `:name`, `:motd`, `:description`, `:language`, `:country`
    * `:profile` - default room profile (default "opus-high")
    * `:max_members` - server-wide limit (default 32)
    * `:password` - server password
    * `:hidden` - announce without name or description
    * `:allow` - identity hex list allowed on the server
    * `:ops` - operator identity hex list
    * `:require_identity` - default for rooms
    * `:rooms` - list of room specs (see `Partyline.Server.Room`);
      default one room, "Lobby"
    * `:state_dir` - directory for operators.txt and banned.txt; nil
      keeps both in memory
    * `:announce_interval` - ms (default 3_300_000)
    * `:listen_opts` - extra options for `Transport.listen/3`

  ## Not yet supported

    * Dial-in (needs LXST telephony). DIALIN requests get the reference's
      "this server has no dial-in" notice.
    * Operator room add/edit/remove (needs Resource transfers for large
      specs). MOTD changes and small ROOM_GET replies work.
  """

  use GenServer

  import Bitwise

  require Logger

  alias Partyline.{Profile, Protocol, Transport}
  alias Partyline.Protocol.{AnnounceData, Assignment, Batch, Channel, Hello, Text, User, Welcome}
  alias Partyline.Server.{Member, Room}

  @hello_timeout 25_000
  @identity_grace 2_000
  @deny_close_delay 500
  @max_pending_links 16
  @password_free_tries 2
  @password_backoff 2.0
  @password_backoff_max 300.0
  @password_forget 3_600.0
  @max_password_records 4_096
  @wrong_password "wrong password"
  @admin_actions ~w(kick ban mute unmute op deop move)

  # ==========================================================================
  # API
  # ==========================================================================

  def start_link(opts) do
    gen_opts = if name = opts[:register], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Destination hash clients connect to."
  def destination_hash(server), do: GenServer.call(server, :destination_hash)

  @doc "Admitted members as `%User{}` records."
  def members(server), do: GenServer.call(server, :members)

  @doc "Rooms as `%Channel{}` records."
  def channels(server), do: GenServer.call(server, :channels)

  # ==========================================================================
  # Init
  # ==========================================================================

  @impl true
  def init(opts) do
    adapter = Keyword.get(opts, :adapter, Partyline.Transport.RNS)
    profile = Keyword.get(opts, :profile, "opus-high")
    max_members = Keyword.get(opts, :max_members, 32)
    state_dir = Keyword.get(opts, :state_dir)

    defaults = [
      profile: profile,
      max_members: max_members,
      require_identity: Keyword.get(opts, :require_identity, false)
    ]

    with :ok <- check_profile(profile),
         {:ok, rooms} <- build_rooms(Keyword.get(opts, :rooms) || [%{"name" => "Lobby"}], defaults),
         {:ok, allowed} <- Room.hash_set(nonempty_list(opts[:allow]), "server", "allow"),
         {:ok, ops} <- Room.hash_set(Keyword.get(opts, :ops, []), "server", "ops") do
      state = %{
        adapter: adapter,
        name: Text.clean_name(opts[:name], "Partyline server"),
        motd: Text.clean(Keyword.get(opts, :motd, ""), Text.max_text()),
        description:
          Text.clean(Keyword.get(opts, :description, ""), Text.max_announce_description()),
        language: Text.clean(Keyword.get(opts, :language, ""), Text.max_locale()),
        country: Text.clean(Keyword.get(opts, :country, ""), Text.max_locale()),
        max_members: max_members,
        password: nonempty(opts[:password]),
        hidden: opts[:hidden] == true,
        allowed: allowed,
        operators: MapSet.union(ops, load_hashes(state_dir, "operators.txt")),
        banned: load_hashes(state_dir, "banned.txt"),
        state_dir: state_dir,
        rooms: rooms,
        default_room: 1,
        members: %{},
        by_link: %{},
        next_id: 1,
        password_failures: %{},
        listener: nil
      }

      listen_opts =
        Keyword.merge(
          [
            app_data: announce_data(state),
            announce_interval: Keyword.get(opts, :announce_interval, 3_300_000)
          ],
          Keyword.get(opts, :listen_opts, [])
        )

      case Transport.listen(adapter, Keyword.fetch!(opts, :identity), listen_opts) do
        {:ok, listener} -> {:ok, %{state | listener: listener}}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp check_profile(profile) do
    if Profile.valid_name?(profile), do: :ok, else: {:error, "unknown profile #{inspect(profile)}"}
  end

  defp build_rooms([], _defaults), do: {:error, "a server needs at least one room"}

  defp build_rooms(specs, defaults) do
    specs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {spec, id}, {:ok, acc} ->
      case Room.new(id, spec, defaults) do
        {:ok, room} -> {:cont, {:ok, Map.put(acc, id, room)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp announce_data(%{hidden: true} = state), do: AnnounceData.pack("", announce_flags(state))

  defp announce_data(state) do
    AnnounceData.pack(state.name, announce_flags(state),
      description: state.description,
      language: state.language,
      country: state.country
    )
  end

  defp announce_flags(state) do
    0
    |> bor(if state.hidden, do: AnnounceData.flag_hidden(), else: 0)
    |> bor(if state.password, do: AnnounceData.flag_password(), else: 0)
    |> bor(if state.allowed, do: AnnounceData.flag_allowlist(), else: 0)
  end

  # ==========================================================================
  # Calls
  # ==========================================================================

  @impl true
  def handle_call(:destination_hash, _from, state),
    do: {:reply, state.listener.destination_hash, state}

  def handle_call(:members, _from, state),
    do: {:reply, Enum.map(admitted(state), &Member.to_user/1), state}

  def handle_call(:channels, _from, state), do: {:reply, channel_list(state), state}

  # ==========================================================================
  # Transport events
  # ==========================================================================

  @impl true
  def handle_info({:partyline_transport, link, {:incoming, info}}, state) do
    if admitted_count(state) >= state.max_members do
      Logger.notice("[Partyline.Server] server full, refusing link")
      {:noreply, deny_and_close(state, link, 0.0, nil, "server is full")}
    else
      state = evict_if_too_many_pending(state)
      member = Member.new(state.next_id, link, info)
      Process.send_after(self(), {:hello_timeout, member.id}, @hello_timeout)

      state = %{
        state
        | next_id: state.next_id + 1,
          members: Map.put(state.members, member.id, member),
          by_link: Map.put(state.by_link, link, member.id)
      }

      {:noreply, state}
    end
  end

  def handle_info({:partyline_transport, link, {:identified, hash}}, state) do
    {:noreply, with_link(state, link, &identified(&1, &2, hash))}
  end

  def handle_info({:partyline_transport, link, {:packet, packet}}, state) do
    {:noreply, with_link(state, link, &packet(&1, &2, packet))}
  end

  def handle_info({:partyline_transport, link, {:closed, _reason}}, state) do
    {:noreply, remove_link(state, link)}
  end

  def handle_info({:hello_timeout, id}, state) do
    case state.members[id] do
      %Member{admitted: false} = m ->
        Logger.notice("[Partyline.Server] member #{id} sent no hello in time, dropping")
        Transport.close_link(m.link)
        {:noreply, remove_member(state, m)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:identity_grace, id}, state) do
    case state.members[id] do
      %Member{admitted: false, pending_hello: %Hello{} = hello} = m ->
        {:noreply, admit_hello(state, %{m | pending_hello: nil}, hello)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:close_link, link}, state) do
    Transport.close_link(link)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp with_link(state, link, fun) do
    case Map.fetch(state.by_link, link) do
      {:ok, id} -> fun.(state, state.members[id])
      :error -> state
    end
  end

  # ==========================================================================
  # Identity
  # ==========================================================================

  defp identified(state, member, hash) do
    known = member.identity != nil
    member = %{member | identity: hash}
    state = put_member(state, member)

    cond do
      MapSet.member?(state.banned, hash) ->
        drop_banned(state, member)

      member.pending_hello != nil ->
        admit_hello(state, %{member | pending_hello: nil}, member.pending_hello)

      known or not member.admitted ->
        state

      true ->
        # Identity after admission: re-check sessions, operator status
        # and whether a broadcast room now lets this member speak.
        state = evict_older_sessions(state, member)
        member = %{member | operator: MapSet.member?(state.operators, hash)}
        member = refresh_speaker(state, member)
        state = put_member(state, member)
        broadcast(state, {:user, Member.to_user(member)})
        state
    end
  end

  defp refresh_speaker(_state, %Member{room: nil} = member), do: member

  defp refresh_speaker(state, member) do
    room = state.rooms[member.room]
    can = Room.can_speak?(room, member.identity)

    if can != member.speaker do
      member = %{member | speaker: can}
      send_to(member, {:room, assignment(room, can)})
      member
    else
      member
    end
  end

  defp drop_banned(state, member) do
    Logger.notice("[Partyline.Server] #{Member.label(member)} is banned, dropping")
    state = remove_member(state, member)

    deny_and_close(
      state,
      member.link,
      Member.capped_rtt(member),
      nil,
      "you are banned from this server"
    )
  end

  defp evict_older_sessions(state, member) do
    state.members
    |> Map.values()
    |> Enum.filter(&(&1.id != member.id and &1.admitted and &1.identity == member.identity))
    |> Enum.reduce(state, fn other, state ->
      Logger.notice("[Partyline.Server] #{Member.label(other)} replaced by a new session")
      Transport.close_link(other.link)
      remove_member(state, other)
    end)
  end

  # ==========================================================================
  # Packets
  # ==========================================================================

  defp packet(state, member, packet) do
    case Protocol.decode_from_client(packet) do
      {:ok, messages} when member.admitted ->
        Enum.reduce(messages, state, &dispatch(&2, member.id, &1))

      {:ok, messages} ->
        pre_admission(state, member, messages)

      {:error, _} ->
        put_member(state, %{member | rejected_frames: member.rejected_frames + 1})
    end
  end

  # Earlier messages in the same packet may have changed the member (room,
  # rate buckets), so re-read it for each one.
  defp dispatch(state, member_id, message) do
    case state.members[member_id] do
      nil -> state
      member -> handle_message(state, member, message)
    end
  end

  # Before admission only HELLO counts, and only the first one.
  defp pre_admission(state, member, messages) do
    hello = Enum.find_value(messages, &hello_of/1)
    malformed = Enum.any?(messages, &match?({:malformed, 0x05, _}, &1))

    cond do
      hello != nil and not member.hello_started ->
        hello_received(state, %{member | hello_started: true}, hello)

      malformed ->
        Logger.notice("[Partyline.Server] member #{member.id} sent a malformed hello, dropping")
        Transport.close_link(member.link)
        remove_member(state, member)

      true ->
        state
    end
  end

  defp hello_of({:hello, hello}), do: hello
  defp hello_of(_), do: nil

  defp handle_message(state, member, {:frames, frames, seq}), do: relay(state, member, frames, seq)
  defp handle_message(state, member, {:move, room_id, pw}), do: move(state, member, room_id, pw)
  defp handle_message(state, member, {:text, text}), do: text(state, member, text)

  defp handle_message(state, member, {:state, muted, deaf}),
    do: set_state(state, member, muted, deaf)

  defp handle_message(state, member, {:poke, target, text}), do: poke(state, member, target, text)

  defp handle_message(state, member, {:admin, a, target, arg}),
    do: admin(state, member, a, target, arg)

  defp handle_message(state, member, {:config, action, payload}),
    do: config(state, member, action, payload)

  defp handle_message(state, member, :talk_end), do: relay_end(state, member)

  defp handle_message(state, member, {:dialin, action, _arg}) do
    with_control(state, member, fn state, member ->
      if action in Protocol.dialin_actions(), do: notice(member, "this server has no dial-in")
      state
    end)
  end

  defp handle_message(state, member, {:malformed, 0x01, _}),
    do: put_member(state, %{member | rejected_frames: member.rejected_frames + 1})

  defp handle_message(state, _member, _other), do: state

  # ==========================================================================
  # Admission
  # ==========================================================================

  defp hello_received(state, member, hello) do
    room = if hello.room == nil, do: default_room(state), else: find_room(state, hello.room)

    needs_identity =
      state.allowed != nil or state.password != nil or not admits_guests?(state) or
        (room != nil and (Room.requires_identity?(room) or room.password != nil))

    if needs_identity and member.identity == nil do
      grace = max(@identity_grace, trunc(4_000 * Member.capped_rtt(member)))
      Process.send_after(self(), {:identity_grace, member.id}, grace)
      put_member(state, %{member | pending_hello: hello})
    else
      admit_hello(state, member, hello)
    end
  end

  # Server-wide checks in reference order; the server password last.
  defp admit_hello(state, member, %Hello{} = hello) do
    rtt = Member.capped_rtt(member)

    case refusal(state, member, hello) do
      :banned -> drop_banned(state, member)
      reason when is_binary(reason) -> deny_drop(state, member, rtt, reason)
      nil when state.password != nil -> check_server_password(state, member, hello, rtt)
      nil -> finish_hello(state, member, hello, rtt)
    end
  end

  defp refusal(state, member, hello) do
    cond do
      hello.ver != Partyline.protocol_version() ->
        Logger.notice(
          "[Partyline.Server] #{Member.label(member)} speaks protocol #{inspect(hello.ver)}, dropping"
        )

        "this server speaks Partyline protocol #{Partyline.protocol_version()}, " <>
          "your client speaks #{inspect(hello.ver)}: Please update"

      listed?(state.banned, member.identity) ->
        :banned

      state.allowed != nil and not listed?(state.allowed, member.identity) ->
        "you are not on this server's allow list"

      member.identity == nil and not admits_guests?(state) ->
        "this server requires an identified user"

      true ->
        nil
    end
  end

  defp listed?(_set, nil), do: false
  defp listed?(set, identity), do: MapSet.member?(set, identity)

  defp check_server_password(state, member, hello, rtt) do
    wait = password_wait(state, nil, member)

    cond do
      wait > 0 ->
        deny_drop(state, member, rtt, "too many wrong passwords, try again in #{wait} s")

      not Room.same_password?(hello.server_password, state.password) ->
        state =
          if is_binary(hello.server_password), do: password_failed(state, nil, member), else: state

        deny_drop(state, member, rtt, "wrong server password")

      true ->
        state |> password_passed(nil, member) |> finish_hello(member, hello, rtt)
    end
  end

  defp finish_hello(state, member, hello, rtt) do
    member = %{
      member
      | name: unique_name(state, Text.clean_name(hello.name, "guest-#{member.id}"), member),
        text_only: hello.text_only,
        muted: hello.muted or hello.text_only,
        deaf: hello.deaf or hello.text_only,
        hops: hello.hops,
        rtt_ms: hello.rtt
    }

    if admitted_count(state) >= state.max_members do
      deny_drop(state, member, rtt, "server is full")
    else
      member = %{
        member
        | admitted: true,
          operator: member.identity != nil and MapSet.member?(state.operators, member.identity)
      }

      admit(put_member(state, member), member, hello)
    end
  end

  # Reference order: WELCOME, CHANNEL batches, USER batches, SYNCED, then
  # ROOM (or DENIED and a default-room fallback), then broadcast USER.
  defp admit(state, member, hello) do
    state = if member.identity, do: evict_older_sessions(state, member), else: state

    send_to(
      member,
      {:welcome,
       %Welcome{
         name: state.name,
         sid: member.id,
         motd: state.motd,
         ver: Partyline.protocol_version(),
         app: Partyline.reference_app_version()
       }}
    )

    users = for m <- admitted(state), m.id != member.id, do: Member.to_user(m)

    for batch <- Batch.record_batches(channel_list(state), member.mdu, &Channel.to_wire/1),
        do: send_to(member, {:channels, batch})

    for batch <- Batch.record_batches(users, member.mdu, &User.to_wire/1),
        do: send_to(member, {:users, batch})

    send_to(member, :synced)

    room = if hello.room == nil, do: default_room(state), else: find_room(state, hello.room)

    {state, reason} =
      if room,
        do: join(state, member, room, hello.password),
        else: {state, no_such_room(hello.room)}

    state = if reason, do: admission_fallback(state, member, room, reason), else: state

    member = state.members[member.id]
    broadcast(state, {:user, Member.to_user(member)})

    Logger.notice(
      "[Partyline.Server] #{Member.label(member)} joined #{room_name(state, member)}, " <>
        "#{admitted_count(state)} on server"
    )

    state
  end

  defp admission_fallback(state, member, room, reason) do
    member = state.members[member.id]
    if room, do: send_to(member, {:denied, room.id, reason}), else: notice(member, reason)
    default = default_room(state)

    if room != nil and room.id == default.id do
      send_to(member, {:room, :none})
      state
    else
      case enter(state, member, default, nil) do
        {state, nil} ->
          state

        {state, _reason} ->
          send_to(member, {:room, :none})
          state
      end
    end
  end

  defp room_name(_state, %Member{room: nil}), do: "no room"
  defp room_name(state, %Member{room: id}), do: state.rooms[id].name

  defp no_such_room(wanted) when is_integer(wanted), do: "no such room #{wanted}"
  defp no_such_room(wanted), do: String.trim("no such room #{Text.clean_name(wanted, "")}")

  defp admits_guests?(state),
    do: Enum.any?(Map.values(state.rooms), &(not Room.requires_identity?(&1)))

  defp default_room(state), do: state.rooms[state.default_room]

  defp find_room(state, id) when is_integer(id), do: state.rooms[id]

  defp find_room(state, name) when is_binary(name) do
    key = name |> String.trim() |> String.downcase()
    Enum.find(Map.values(state.rooms), &(String.downcase(&1.name) == key))
  end

  defp find_room(_state, _), do: nil

  defp unique_name(state, name, member) do
    taken =
      for other <- admitted(state),
          other.id != member.id,
          not (member.identity != nil and other.identity == member.identity),
          into: MapSet.new(),
          do: Text.name_key(other.name)

    Stream.iterate(2, &(&1 + 1))
    |> Enum.reduce_while(name, fn n, candidate ->
      if MapSet.member?(taken, Text.name_key(candidate)) do
        tail = " (#{n})"
        {:cont, Text.clean(name, Text.max_name() - byte_size(tail)) <> tail}
      else
        {:halt, candidate}
      end
    end)
  end

  # ==========================================================================
  # Rooms
  # ==========================================================================

  # join/4 is enter/4 plus password backoff.
  defp join(state, member, room, password) do
    wait = if room.password, do: password_wait(state, room.id, member), else: 0

    if wait > 0 do
      {state, "too many wrong passwords, try again in #{wait} s"}
    else
      {state, reason} = enter(state, member, room, password)

      state =
        cond do
          reason == @wrong_password and is_binary(password) ->
            password_failed(state, room.id, member)

          reason == nil and room.password != nil ->
            password_passed(state, room.id, member)

          true ->
            state
        end

      {state, reason}
    end
  end

  defp enter(state, member, room, password) do
    member = state.members[member.id]
    room = state.rooms[room.id]

    case Room.check(room, member.identity, password) do
      nil ->
        state = leave_room(state, member)

        room = %{
          state.rooms[room.id]
          | members: MapSet.put(state.rooms[room.id].members, member.id)
        }

        speaker = Room.can_speak?(room, member.identity)
        member = Member.reset_frames(%{member | room: room.id, speaker: speaker}, room.frame_ms)
        send_to(member, {:room, assignment(room, speaker)})
        state = %{state | rooms: Map.put(state.rooms, room.id, room)}
        {put_member(state, member), nil}

      reason ->
        {state, reason}
    end
  end

  defp leave_room(state, %Member{room: nil}), do: state

  defp leave_room(state, %Member{room: id} = member) do
    case state.rooms[id] do
      nil ->
        state

      room ->
        room = %{room | members: MapSet.delete(room.members, member.id)}
        %{state | rooms: Map.put(state.rooms, id, room)}
    end
  end

  defp assignment(room, speaker) do
    %Assignment{
      room_id: room.id,
      profile: room.profile,
      frame_ms: room.frame_ms,
      can_speak: speaker
    }
  end

  defp channel_list(state) do
    for id <- Enum.sort(Map.keys(state.rooms)), do: Room.to_channel(state.rooms[id])
  end

  defp move(state, member, room_id, password) do
    with_control(state, member, &do_move(&1, &2, room_id, password))
  end

  defp do_move(state, member, room_id, password) do
    room = if is_integer(room_id), do: state.rooms[room_id]

    cond do
      room == nil ->
        send_to(member, {:denied, if(is_integer(room_id), do: room_id), "no such room"})
        state

      room.id == member.room ->
        state

      true ->
        state |> join(member, room, password) |> moved(member, room)
    end
  end

  defp moved({state, nil}, member, room) do
    broadcast(state, {:user, Member.to_user(state.members[member.id])})
    Logger.notice("[Partyline.Server] #{Member.label(member)} moved to #{room.name}")
    state
  end

  defp moved({state, reason}, member, room) do
    send_to(member, {:denied, room.id, reason})
    state
  end

  # ==========================================================================
  # Audio
  # ==========================================================================

  defp relay(state, %Member{room: nil}, _frames, _seq), do: state
  defp relay(state, %Member{server_muted: true}, _frames, _seq), do: state
  defp relay(state, %Member{speaker: false}, _frames, _seq), do: state

  defp relay(state, member, frames, seq) do
    room = state.rooms[member.room]

    case Member.allow_frames(member, length(frames)) do
      {false, member} ->
        put_member(state, %{member | limited_frames: member.limited_frames + length(frames)})

      {true, member} ->
        if Enum.all?(frames, &Profile.valid_frame?(&1, room.profile)) do
          state = put_member(state, %{member | talking: true})
          fan_out(state, room, member, frames, seq)
          state
        else
          put_member(state, %{member | rejected_frames: member.rejected_frames + 1})
        end
    end
  end

  # One encoding for everyone whose MDU carries it; re-split per
  # recipient otherwise, as the reference relay_split does.
  defp fan_out(state, room, member, frames, seq) do
    packet = Protocol.encode_to_client({:frames, member.id, frames, seq})

    for target <- room_targets(state, room, member) do
      if byte_size(packet) <= target.mdu,
        do: Transport.send_packet(target.link, packet),
        else: relay_split(target, member.id, frames, seq)
    end

    :ok
  end

  defp relay_split(target, speaker_id, frames, seq) do
    for {chunk, offset} <- Batch.relay_chunks(frames, target.mdu) do
      chunk_seq = if seq, do: band(seq + offset, 0xFFFF)
      send_to(target, {:frames, speaker_id, chunk, chunk_seq})
    end
  end

  defp relay_end(
         state,
         %Member{talking: true, room: room_id, server_muted: false, speaker: true} = member
       )
       when room_id != nil do
    state = put_member(state, %{member | talking: false})
    packet = Protocol.encode_to_client({:talk_end, member.id})

    for t <- room_targets(state, state.rooms[room_id], member),
        do: Transport.send_packet(t.link, packet)

    state
  end

  defp relay_end(state, _member), do: state

  defp room_targets(state, room, sender) do
    for id <- room.members,
        id != sender.id,
        m <- List.wrap(state.members[id]),
        not m.deaf,
        do: m
  end

  # ==========================================================================
  # Chat and state
  # ==========================================================================

  defp text(state, member, text) do
    text = Text.clean(text, Text.max_text())

    if text == "" or member.room == nil do
      state
    else
      case Member.allow_text(member) do
        {false, member} ->
          put_member(state, member)

        {true, member} ->
          state = put_member(state, member)
          # The sender shows its own copy; everyone else in the room gets it.
          broadcast(state, {:text, member.id, text}, room: member.room, exclude: member.id)
          state
      end
    end
  end

  defp poke(state, member, target_id, text) do
    text = Text.clean(text, Text.max_text())

    case Member.allow_text(member) do
      {false, member} ->
        put_member(state, member)

      {true, member} ->
        state = put_member(state, member)

        case state.members[target_id] do
          %Member{admitted: true} = target when target.id != member.id ->
            send_to(target, {:poke, member.id, text})

          _ ->
            :ok
        end

        state
    end
  end

  defp set_state(state, member, muted, deaf) do
    with_control(state, member, fn state, member ->
      if {muted, deaf} == {member.muted, member.deaf} do
        state
      else
        update_and_broadcast(state, %{member | muted: muted, deaf: deaf})
      end
    end)
  end

  defp with_control(state, member, fun) do
    case Member.allow_control(member) do
      {true, member} -> fun.(put_member(state, member), member)
      {false, member} -> put_member(state, member)
    end
  end

  # ==========================================================================
  # Operators
  # ==========================================================================

  defp admin(state, operator, action, target_id, argument) do
    target = if is_integer(target_id), do: state.members[target_id]

    cond do
      not operator.operator ->
        notice(operator, "operators only")
        state

      action not in @admin_actions ->
        state

      target == nil or not target.admitted ->
        notice(operator, "no such user")
        state

      target.id == operator.id and action != "move" ->
        notice(operator, "not on yourself")
        state

      true ->
        Logger.notice(
          "[Partyline.Server] operator #{Member.label(operator)}: #{action} on #{Member.label(target)}"
        )

        do_admin(state, operator, action, target, argument)
    end
  end

  defp do_admin(state, op, "kick", target, _arg), do: kick(state, target, "kicked by #{op.name}")

  defp do_admin(state, op, "ban", %Member{identity: nil}, _arg) do
    notice(op, "anonymous users cannot be banned")
    state
  end

  defp do_admin(state, op, "ban", target, _arg) do
    state = %{state | banned: MapSet.put(state.banned, target.identity)}
    save_hashes(state.state_dir, "banned.txt", state.banned)
    kick(state, target, "banned by #{op.name}")
  end

  defp do_admin(state, op, "mute", target, _arg) do
    state = update_and_broadcast(state, %{target | server_muted: true})
    notice(target, "You were muted by operator #{op.name}.")
    state
  end

  defp do_admin(state, op, "unmute", target, _arg) do
    state = update_and_broadcast(state, %{target | server_muted: false})
    notice(target, "You were unmuted by operator #{op.name}.")
    state
  end

  defp do_admin(state, op, "op", %Member{identity: nil}, _arg) do
    notice(op, "anonymous users cannot be operators")
    state
  end

  defp do_admin(state, op, "op", target, _arg) do
    state = %{state | operators: MapSet.put(state.operators, target.identity)}
    save_hashes(state.state_dir, "operators.txt", state.operators)
    state = update_and_broadcast(state, %{target | operator: true})
    notice(target, "You are now an operator, promoted by #{op.name}.")
    state
  end

  defp do_admin(state, op, "deop", target, _arg) do
    state =
      if target.identity do
        ops = MapSet.delete(state.operators, target.identity)
        save_hashes(state.state_dir, "operators.txt", ops)
        %{state | operators: ops}
      else
        state
      end

    state = update_and_broadcast(state, %{target | operator: false})
    notice(target, "You are no longer an operator, demoted by #{op.name}.")
    state
  end

  defp do_admin(state, op, "move", target, room_id) do
    room = if is_integer(room_id), do: state.rooms[room_id]

    cond do
      room == nil ->
        notice(op, "no such room")
        state

      room.id == target.room ->
        state

      true ->
        # Operators bypass the room password, not the allow list.
        state |> enter(target, room, room.password) |> operator_moved(op, target, room)
    end
  end

  defp operator_moved({state, nil}, op, target, room) do
    broadcast(state, {:user, Member.to_user(state.members[target.id])})

    if target.id != op.id,
      do: notice(target, "You were moved to #{room.name} by operator #{op.name}.")

    state
  end

  defp operator_moved({state, reason}, op, _target, room) do
    send_to(op, {:denied, room.id, reason})
    state
  end

  defp kick(state, target, reason),
    do: deny_and_close(state, target.link, Member.capped_rtt(target), nil, reason)

  defp update_and_broadcast(state, member) do
    state = put_member(state, member)
    broadcast(state, {:user, Member.to_user(member)})
    state
  end

  # Operator configuration: MOTD and small ROOM_GET replies only.
  defp config(state, member, action, payload) do
    with_control(state, member, fn state, member ->
      cond do
        action not in Protocol.config_actions() ->
          state

        not member.operator ->
          notice(member, "operators only")
          state

        action == "motd" ->
          motd = Text.clean(payload, Text.max_text())
          state = %{state | motd: motd}
          broadcast(state, {:config, ["motd", motd]})
          state

        action == "room_get" ->
          room_get(state, member, payload)

        true ->
          notice(member, "room changes are not supported by this server yet")
          state
      end
    end)
  end

  defp room_get(state, member, room_id) do
    case is_integer(room_id) && state.rooms[room_id] do
      %Room{} = room ->
        packet = Protocol.encode_to_client({:config, ["room", room.id, room.spec]})

        if byte_size(packet) <= member.mdu,
          do: Transport.send_packet(member.link, packet),
          else: notice(member, "room settings too large to send without a resource transfer")

        state

      _ ->
        notice(member, "no such room")
        state
    end
  end

  # ==========================================================================
  # Membership bookkeeping
  # ==========================================================================

  defp put_member(state, %Member{} = m), do: %{state | members: Map.put(state.members, m.id, m)}

  defp admitted(state) do
    state.members |> Map.values() |> Enum.filter(& &1.admitted) |> Enum.sort_by(& &1.id)
  end

  defp admitted_count(state), do: Enum.count(Map.values(state.members), & &1.admitted)

  defp remove_link(state, link) do
    case Map.fetch(state.by_link, link) do
      {:ok, id} -> remove_member(state, state.members[id])
      :error -> state
    end
  end

  defp remove_member(state, nil), do: state

  defp remove_member(state, member) do
    state = leave_room(state, member)

    state = %{
      state
      | members: Map.delete(state.members, member.id),
        by_link: Map.delete(state.by_link, member.link)
    }

    if member.admitted do
      broadcast(state, {:user_left, member.id})

      Logger.notice(
        "[Partyline.Server] #{Member.label(member)} left, #{admitted_count(state)} on server " <>
          "(rejected #{member.rejected_frames} frames, rate limited #{member.limited_frames})"
      )
    end

    state
  end

  defp evict_if_too_many_pending(state) do
    waiting = Enum.reject(Map.values(state.members), & &1.admitted)

    if length(waiting) >= @max_pending_links do
      idle = Enum.reject(waiting, & &1.hello_started)
      oldest = Enum.min_by(if(idle == [], do: waiting, else: idle), & &1.joined_at)
      Logger.notice("[Partyline.Server] member #{oldest.id} dropped to make room for a new link")
      Transport.close_link(oldest.link)
      remove_member(state, oldest)
    else
      state
    end
  end

  # Refuse a link: DENIED with room nil, then tear down once it has had
  # time to arrive.
  defp deny_and_close(state, link, rtt, room_id, reason) do
    Transport.send_packet(link, Protocol.encode_to_client({:denied, room_id, reason}))
    Process.send_after(self(), {:close_link, link}, max(@deny_close_delay, trunc(2_000 * rtt)))
    state
  end

  defp deny_drop(state, member, rtt, reason) do
    state = put_member(state, member)
    deny_and_close(state, member.link, rtt, nil, reason)
  end

  # ==========================================================================
  # Sending
  # ==========================================================================

  defp send_to(%Member{link: link}, message),
    do: Transport.send_packet(link, Protocol.encode_to_client(message))

  defp notice(member, text), do: send_to(member, {:notice, text})

  defp broadcast(state, message, opts \\ []) do
    packet = Protocol.encode_to_client(message)
    exclude = Keyword.get(opts, :exclude)

    pool =
      case Keyword.get(opts, :room) do
        nil -> admitted(state)
        room_id -> for id <- state.rooms[room_id].members, m <- List.wrap(state.members[id]), do: m
      end

    for m <- pool, m.id != exclude, do: Transport.send_packet(m.link, packet)
    :ok
  end

  # ==========================================================================
  # Password backoff: 2 free tries, then 2 s doubling up to 300 s,
  # forgotten after an hour.
  # ==========================================================================

  defp password_key(target, member), do: {target, member.identity}

  defp password_wait(state, target, member) do
    case Map.fetch(state.password_failures, password_key(target, member)) do
      {:ok, {_failures, retry_at}} -> max(0, ceil(retry_at - Member.now()))
      :error -> 0
    end
  end

  defp password_failed(state, target, member) do
    key = password_key(target, member)
    now = Member.now()

    failures =
      case Map.fetch(state.password_failures, key) do
        {:ok, {f, retry_at}} -> if now - retry_at > @password_forget, do: 1, else: f + 1
        :error -> 1
      end

    delay =
      if failures > @password_free_tries do
        exponent = min(failures - @password_free_tries - 1, 16)
        min(@password_backoff_max, @password_backoff * :math.pow(2, exponent))
      else
        0.0
      end

    records = Map.put(state.password_failures, key, {failures, now + delay})

    records =
      if map_size(records) > @max_password_records do
        {oldest, _} = Enum.min_by(records, fn {_k, {_f, at}} -> at end)
        Map.delete(records, oldest)
      else
        records
      end

    %{state | password_failures: records}
  end

  defp password_passed(state, target, member),
    do: %{
      state
      | password_failures: Map.delete(state.password_failures, password_key(target, member))
    }

  # ==========================================================================
  # Persistence
  # ==========================================================================

  defp load_hashes(nil, _file), do: MapSet.new()

  defp load_hashes(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} ->
        for line <- String.split(text, "\n"),
            entry <- [line |> String.split("#") |> hd() |> String.trim()],
            entry != "",
            {:ok, hash} <- [Room.parse_hash(entry)],
            into: MapSet.new(),
            do: hash

      {:error, _} ->
        MapSet.new()
    end
  end

  defp save_hashes(nil, _file, _set), do: :ok

  defp save_hashes(dir, file, set) do
    File.mkdir_p!(dir)
    path = Path.join(dir, file)

    body =
      set
      |> Enum.map(&Base.encode16(&1, case: :lower))
      |> Enum.sort()
      |> Enum.map_join(&(&1 <> "\n"))

    File.write!(path <> ".tmp", body)
    File.rename!(path <> ".tmp", path)
  end

  defp nonempty(s) when is_binary(s) and s != "", do: s
  defp nonempty(_), do: nil

  defp nonempty_list([_ | _] = list), do: list
  defp nonempty_list(_), do: nil
end
