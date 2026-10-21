defmodule Partyline.Protocol do
  @moduledoc """
  Partyline wire format, protocol version 1.

  Every link packet is one msgpack map with small-integer keys
  (`FIELD_*`). One packet may carry several fields. HELLO and WELCOME
  values are string-keyed maps; everything else is scalars or arrays.

  ## Typing

  msgpack `bin` and `str` are distinct on the wire and the reference
  depends on it: audio frames must be `bin` (the server checks for
  Python `bytes`), text must be `str`. Encoding wraps frames in
  `Msgpax.Bin`; decoding unpacks with `binary: true` so a `str` where a
  frame belongs, or a `bin` where text belongs, is caught.

  ## Messages

  Encoders take lists of tagged tuples; decoders return them, in the
  order the reference handler processes fields. Fields that fail the
  reference's checks decode to `{:malformed, field, value}` so callers
  can count or log them the way the reference counts rejected frames.

  Client to server (`encode_to_server/1`, `decode_from_client/1`):

      {:hello, %Hello{}}
      {:frames, [binary], seq | nil}
      {:move, room_id, password | nil}
      {:text, text}
      {:state, muted, deaf}
      {:poke, target_id, text}
      {:admin, action, target_id, argument}
      {:dialin, action, argument}
      {:config, action, payload}
      :talk_end

  Server to client (`encode_to_client/1`, `decode_from_server/1`):

      {:welcome, %Welcome{}}
      {:channels, [%Channel{}]}     # encodes as a record batch
      {:users, [%User{}]}           # encodes as a record batch
      {:user, %User{}}              # encodes as a single record
      {:user_left, member_id}
      :synced
      {:room, %Assignment{} | :none}
      {:denied, room_id | nil, reason}
      {:notice, text}
      {:text, member_id, text}
      {:poke, from_id, text}
      {:dialin, event, identity_hex}
      {:config, [term]}
      {:channel_gone, room_id}
      {:talk_end, member_id}
      {:frames, speaker_id, [binary | nil], seq | nil}

  `decode_from_server/1` (run by clients) mirrors the reference client:
  received records and text are sanitized, and records decode into
  structs. A received batch of frames keeps a `nil` in place of any
  element that isn't `bin`, so per-frame sequence offsets stay correct.

  `decode_from_client/1` (run by servers) passes text and names through
  raw, because the server sanitizes them with member context (fallback
  names use the member id), and rejects a frame batch as a whole if any
  element isn't `bin`, as the reference server does.
  """

  import Bitwise

  alias Partyline.Protocol.{Assignment, Channel, Hello, OrderedMap, Text, User, Welcome}

  # Field keys (partyline common.py).
  @field_frames 0x01
  @field_speaker 0x02
  @field_room 0x03
  @field_hello 0x05
  @field_welcome 0x06
  @field_channel 0x07
  @field_user 0x08
  @field_user_left 0x09
  @field_move 0x0A
  @field_denied 0x0B
  @field_text 0x0C
  @field_state 0x0D
  @field_synced 0x0E
  @field_poke 0x0F
  @field_seq 0x10
  @field_admin 0x11
  @field_notice 0x12
  @field_talk_end 0x13
  @field_dialin 0x14
  @field_config 0x15
  @field_channel_gone 0x16

  @max_batch 64

  @admin_actions ~w(kick ban mute unmute op deop move)
  @dialin_actions ~w(answer reject add remove list)
  @config_actions ~w(motd room_get room_add room_edit room_remove)

  def max_batch, do: @max_batch
  def admin_actions, do: @admin_actions
  def dialin_actions, do: @dialin_actions
  def config_actions, do: @config_actions

  # ==========================================================================
  # Encoding
  # ==========================================================================

  @doc "Pack client-to-server messages into one packet payload."
  @spec encode_to_server(tuple() | atom() | [tuple() | atom()]) :: binary()
  def encode_to_server(messages), do: encode(messages, &server_bound/1)

  @doc "Pack server-to-client messages into one packet payload."
  @spec encode_to_client(tuple() | atom() | [tuple() | atom()]) :: binary()
  def encode_to_client(messages), do: encode(messages, &client_bound/1)

  # Fields are packed in message order, which is the order the reference
  # inserts them into its dict, so output is byte-identical to it.
  defp encode(messages, to_fields) do
    pairs =
      messages
      |> List.wrap()
      |> Enum.flat_map(to_fields)

    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) != length(keys) do
      dupes = keys -- Enum.uniq(keys)
      raise ArgumentError, "fields given twice in one packet: #{inspect(dupes)}"
    end

    Msgpax.pack!(OrderedMap.new(pairs), iodata: false)
  end

  defp server_bound({:hello, %Hello{} = hello}), do: [{@field_hello, Hello.to_wire(hello)}]
  defp server_bound({:frames, frames, seq}), do: frame_fields(frames, seq)
  defp server_bound({:move, room_id, password}), do: [{@field_move, [room_id, password]}]
  defp server_bound({:text, text}), do: [{@field_text, text}]
  defp server_bound({:state, muted, deaf}), do: [{@field_state, [muted, deaf]}]
  defp server_bound({:poke, target, text}), do: [{@field_poke, [target, text]}]

  defp server_bound({:admin, action, target, arg}) when action in @admin_actions,
    do: [{@field_admin, [action, target, arg]}]

  defp server_bound({:dialin, action, arg}) when action in @dialin_actions,
    do: [{@field_dialin, [action, arg]}]

  defp server_bound({:config, action, payload}) when action in @config_actions,
    do: [{@field_config, [action, payload]}]

  defp server_bound(:talk_end), do: [{@field_talk_end, true}]

  defp client_bound({:welcome, %Welcome{} = w}), do: [{@field_welcome, Welcome.to_wire(w)}]

  defp client_bound({:channels, channels}),
    do: [{@field_channel, Enum.map(channels, &Channel.to_wire/1)}]

  defp client_bound({:users, users}), do: [{@field_user, Enum.map(users, &User.to_wire/1)}]
  defp client_bound({:user, %User{} = user}), do: [{@field_user, User.to_wire(user)}]
  defp client_bound({:user_left, id}), do: [{@field_user_left, id}]
  defp client_bound(:synced), do: [{@field_synced, true}]
  defp client_bound({:room, assignment}), do: [{@field_room, Assignment.to_wire(assignment)}]
  defp client_bound({:denied, room_id, reason}), do: [{@field_denied, [room_id, reason]}]
  defp client_bound({:notice, text}), do: [{@field_notice, text}]
  defp client_bound({:text, member_id, text}), do: [{@field_text, [member_id, text]}]
  defp client_bound({:poke, from_id, text}), do: [{@field_poke, [from_id, text]}]
  defp client_bound({:dialin, event, hex}), do: [{@field_dialin, [event, hex]}]
  defp client_bound({:config, record}) when is_list(record), do: [{@field_config, record}]
  defp client_bound({:channel_gone, id}), do: [{@field_channel_gone, id}]
  defp client_bound({:talk_end, member_id}), do: [{@field_talk_end, member_id}]

  # Reference relay order: FRAMES, SPEAKER, SEQ.
  defp client_bound({:frames, speaker, frames, seq}) do
    [{@field_frames, frames_value(frames)}, {@field_speaker, speaker} | seq_field(seq)]
  end

  # Reference packetizer order: FRAMES, SEQ.
  defp frame_fields(frames, seq), do: [{@field_frames, frames_value(frames)} | seq_field(seq)]

  # One frame goes out bare, several as an array (reference packetizer).
  defp frames_value([frame]), do: Msgpax.Bin.new(frame)

  defp frames_value(frames) when is_list(frames) and frames != [],
    do: Enum.map(frames, &Msgpax.Bin.new/1)

  defp seq_field(nil), do: []
  defp seq_field(seq) when is_integer(seq), do: [{@field_seq, seq &&& 0xFFFF}]

  # ==========================================================================
  # Decoding
  # ==========================================================================

  @doc "Decode a packet received by a server."
  @spec decode_from_client(binary()) :: {:ok, list()} | {:error, term()}
  def decode_from_client(data) do
    with {:ok, fields} <- unpack(data) do
      {:ok,
       []
       |> take(fields, @field_hello, &client_hello/1)
       |> take_frames_from_client(fields)
       |> take(fields, @field_move, &client_move/1)
       |> take(fields, @field_text, &{:ok, {:text, &1}})
       |> take(fields, @field_state, &client_state/1)
       |> take(fields, @field_poke, &client_poke/1)
       |> take(fields, @field_admin, &client_admin/1)
       |> take(fields, @field_dialin, &client_dialin/1)
       |> take(fields, @field_config, &client_config/1)
       |> take(fields, @field_talk_end, fn _ -> {:ok, :talk_end} end)
       |> Enum.reverse()}
    end
  end

  @doc "Decode a packet received by a client."
  @spec decode_from_server(binary()) :: {:ok, list()} | {:error, term()}
  def decode_from_server(data) do
    with {:ok, fields} <- unpack(data) do
      {:ok,
       []
       |> take(fields, @field_welcome, &server_welcome/1)
       |> take_records(fields, @field_channel, :channels, &Channel.from_wire/1)
       |> take_records(fields, @field_user, :users, &User.from_wire/1)
       |> take(fields, @field_user_left, &int_message(:user_left, &1))
       |> take(fields, @field_synced, fn _ -> {:ok, :synced} end)
       |> take(fields, @field_room, &server_room/1)
       |> take(fields, @field_denied, &server_denied/1)
       |> take(fields, @field_notice, &{:ok, {:notice, Text.clean(&1, Text.max_text())}})
       |> take(fields, @field_text, &server_pair(:text, &1))
       |> take(fields, @field_poke, &server_pair(:poke, &1))
       |> take(fields, @field_dialin, &server_dialin/1)
       |> take(fields, @field_config, &server_config/1)
       |> take(fields, @field_channel_gone, &int_message(:channel_gone, &1))
       |> take(fields, @field_talk_end, &int_message(:talk_end, &1))
       |> take_frames_from_server(fields)
       |> Enum.reverse()}
    end
  end

  defp unpack(data) when is_binary(data) do
    case Msgpax.unpack(data, binary: true) do
      {:ok, fields} when is_map(fields) -> {:ok, fields}
      {:ok, other} -> {:error, {:not_a_map, other}}
      {:error, reason} -> {:error, {:msgpack, reason}}
    end
  end

  # Run `decoder` on a field if present. Messages accumulate in reverse.
  defp take(acc, fields, key, decoder) do
    case Map.fetch(fields, key) do
      {:ok, value} ->
        case decoder.(value) do
          {:ok, message} -> [message | acc]
          :error -> [{:malformed, key, value} | acc]
        end

      :error ->
        acc
    end
  end

  # --- client to server -----------------------------------------------------

  defp client_hello(value) do
    case Hello.from_wire(value) do
      {:ok, hello} -> {:ok, {:hello, hello}}
      :error -> :error
    end
  end

  # Reference server: a batch of 1..64, every element bytes, else the
  # whole packet's audio is rejected.
  defp take_frames_from_client(acc, fields) do
    take(acc, fields, @field_frames, fn payload ->
      batch = bare_or_list(payload)

      if length(batch) in 1..@max_batch and Enum.all?(batch, &match?(%Msgpax.Bin{}, &1)) do
        {:ok, {:frames, Enum.map(batch, & &1.data), seq(fields)}}
      else
        :error
      end
    end)
  end

  defp client_move([room_id, password | _]), do: {:ok, {:move, room_id, password}}
  defp client_move(_), do: :error

  defp client_state([muted, deaf | _]), do: {:ok, {:state, Text.truthy?(muted), Text.truthy?(deaf)}}
  defp client_state(_), do: :error

  defp client_poke([target, text | _]) when is_integer(target), do: {:ok, {:poke, target, text}}
  defp client_poke(_), do: :error

  defp client_admin([action, target | rest]) when is_integer(target),
    do: {:ok, {:admin, action, target, List.first(rest)}}

  defp client_admin(_), do: :error

  defp client_dialin([action | rest]), do: {:ok, {:dialin, action, List.first(rest)}}
  defp client_dialin(_), do: :error

  defp client_config([action | rest]), do: {:ok, {:config, action, List.first(rest)}}
  defp client_config(_), do: :error

  # --- server to client -----------------------------------------------------

  defp server_welcome(value) do
    case Welcome.from_wire(value) do
      {:ok, welcome} -> {:ok, {:welcome, welcome}}
      :error -> :error
    end
  end

  # One message for the good records, one :malformed per bad record.
  defp take_records(acc, fields, key, tag, decoder) do
    case Map.fetch(fields, key) do
      {:ok, value} ->
        {good, bad} =
          value
          |> record_batch()
          |> Enum.map(fn record -> {record, decoder.(record)} end)
          |> Enum.split_with(fn {_record, result} -> match?({:ok, _}, result) end)

        malformed = Enum.map(bad, fn {record, _} -> {:malformed, key, record} end)
        records = Enum.map(good, fn {_record, {:ok, struct}} -> struct end)

        Enum.reverse(malformed) ++ if(records == [], do: acc, else: [{tag, records} | acc])

      :error ->
        acc
    end
  end

  @doc """
  The reference `record_batch` rule: a list whose first element is itself
  a list is a batch of records; anything else is one record.
  """
  @spec record_batch(term()) :: list()
  def record_batch([first | _] = value) when is_list(first), do: value
  def record_batch(value), do: [value]

  defp server_room(value) do
    case Assignment.from_wire(value) do
      {:ok, assignment} -> {:ok, {:room, assignment}}
      {:error, _} -> :error
    end
  end

  defp server_denied([room_id, reason | _]) when is_integer(room_id) or is_nil(room_id),
    do: {:ok, {:denied, room_id, Text.clean(reason, Text.max_text())}}

  defp server_denied(_), do: :error

  defp server_pair(tag, [id, text | _]) when is_integer(id),
    do: {:ok, {tag, id, Text.clean(text, Text.max_text())}}

  defp server_pair(_tag, _), do: :error

  defp server_dialin([event, hex | _]) when is_binary(hex) and byte_size(hex) == 32,
    do: {:ok, {:dialin, Text.clean(event, 16), hex}}

  defp server_dialin(_), do: :error

  defp server_config([_action | _] = record), do: {:ok, {:config, record}}
  defp server_config(_), do: :error

  defp int_message(tag, id) when is_integer(id), do: {:ok, {tag, id}}
  defp int_message(_tag, _), do: :error

  # Reference client: speaker defaults to 0, up to 64 frames are taken,
  # non-bytes elements are counted as bad frames and skipped individually.
  defp take_frames_from_server(acc, fields) do
    take(acc, fields, @field_frames, fn payload ->
      speaker = Map.get(fields, @field_speaker, 0)

      if is_integer(speaker) do
        frames =
          payload
          |> bare_or_list()
          |> Enum.take(@max_batch)
          |> Enum.map(&frame_data/1)

        {:ok, {:frames, speaker, frames, seq(fields)}}
      else
        :error
      end
    end)
  end

  defp frame_data(%Msgpax.Bin{data: data}), do: data
  defp frame_data(_), do: nil

  # --- shared ---------------------------------------------------------------

  defp bare_or_list(list) when is_list(list), do: list
  defp bare_or_list(single), do: [single]

  defp seq(fields) do
    case Map.get(fields, @field_seq) do
      s when is_integer(s) and s >= 0 and s <= 0xFFFF -> s
      _ -> nil
    end
  end
end
