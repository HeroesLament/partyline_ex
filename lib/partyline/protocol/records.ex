defmodule Partyline.Protocol.Hello do
  @moduledoc """
  FIELD_HELLO (client to server), a string-keyed map. `from_wire/1`
  applies the normalization the reference server does before it needs
  any member context: flags through `bool()`, `hops` kept only as an int
  in 0..255, `rtt` only as a number in [0, 1e6) truncated to int. `name`,
  `room`, passwords, `ver` and `app` are passed through raw; the server
  checks them in context.
  """

  alias Partyline.Protocol.{OrderedMap, Text}

  defstruct name: nil,
            room: nil,
            password: nil,
            server_password: nil,
            text_only: false,
            muted: false,
            deaf: false,
            hops: nil,
            rtt: nil,
            ver: nil,
            app: nil

  @type t :: %__MODULE__{}

  # Key order of the reference client's dict literal.
  @spec to_wire(t()) :: OrderedMap.t()
  def to_wire(%__MODULE__{} = h) do
    OrderedMap.new([
      {"name", h.name},
      {"room", h.room},
      {"password", h.password},
      {"server_password", h.server_password},
      {"text_only", h.text_only},
      {"muted", h.muted},
      {"deaf", h.deaf},
      {"hops", h.hops},
      {"rtt", h.rtt},
      {"ver", h.ver},
      {"app", h.app}
    ])
  end

  @spec from_wire(term()) :: {:ok, t()} | :error
  def from_wire(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       name: map["name"],
       room: map["room"],
       password: map["password"],
       server_password: map["server_password"],
       text_only: Text.truthy?(map["text_only"]),
       muted: Text.truthy?(map["muted"]),
       deaf: Text.truthy?(map["deaf"]),
       hops: hops(map["hops"]),
       rtt: rtt(map["rtt"]),
       ver: map["ver"],
       app: map["app"]
     }}
  end

  def from_wire(_), do: :error

  defp hops(h) when is_integer(h) and h >= 0 and h < 256, do: h
  defp hops(_), do: nil

  defp rtt(r) when is_number(r) and r >= 0 and r < 1.0e6, do: trunc(r)
  defp rtt(_), do: nil
end

defmodule Partyline.Protocol.Welcome do
  @moduledoc "FIELD_WELCOME (server to client), a string-keyed map."

  alias Partyline.Protocol.{OrderedMap, Text}

  @enforce_keys [:sid]
  defstruct [:name, :sid, motd: "", ver: nil, app: nil]

  @type t :: %__MODULE__{}

  # Key order of the reference server's dict literal.
  @spec to_wire(t()) :: OrderedMap.t()
  def to_wire(%__MODULE__{} = w) do
    OrderedMap.new([
      {"name", w.name},
      {"sid", w.sid},
      {"motd", w.motd},
      {"ver", w.ver},
      {"app", w.app}
    ])
  end

  @doc "Client-side read, as in partyline `Client.welcome`."
  @spec from_wire(term()) :: {:ok, t()} | :error
  def from_wire(%{"sid" => sid} = map) when is_integer(sid) do
    {:ok,
     %__MODULE__{
       name: Text.clean_name(map["name"], "server"),
       sid: sid,
       motd: Text.clean(Map.get(map, "motd", ""), Text.max_text()),
       ver: map["ver"],
       app: app(Map.get(map, "app", ""))
     }}
  end

  def from_wire(_), do: :error

  defp app(app) when is_binary(app) do
    case Text.clean(app, 32) do
      "" -> "unknown"
      cleaned -> cleaned
    end
  end

  defp app(_), do: "unknown"
end

defmodule Partyline.Protocol.Channel do
  @moduledoc """
  FIELD_CHANNEL record (server to client):

      [room_id, name, profile, frame_ms, access_flags, description,
       dialin_number, ptt_jitter_ms, room_flags]

  Trailing fields may be absent from older servers.
  """

  import Bitwise

  alias Partyline.Protocol.Text

  @access_identity 1
  @access_allowlist 2
  @access_password 4
  @room_broadcast 1
  @max_jitter_ms 30_000

  @enforce_keys [:id, :name, :profile, :frame_ms]
  defstruct [
    :id,
    :name,
    :profile,
    :frame_ms,
    access: 0,
    description: "",
    dialin_number: nil,
    ptt_jitter_ms: 0,
    flags: 0
  ]

  @type t :: %__MODULE__{}

  @spec to_wire(t()) :: list()
  def to_wire(%__MODULE__{} = c) do
    [
      c.id,
      c.name,
      c.profile,
      c.frame_ms,
      c.access,
      c.description,
      c.dialin_number,
      c.ptt_jitter_ms,
      c.flags
    ]
  end

  @doc "Client-side read, as in partyline `Client.channel`."
  @spec from_wire(term()) :: {:ok, t()} | {:error, term()}
  def from_wire([id, name, profile, frame_ms, access, description | rest])
      when is_integer(id) and is_integer(frame_ms) and is_integer(access) do
    if Partyline.Profile.valid_name?(profile) do
      {:ok,
       %__MODULE__{
         id: id,
         name: Text.clean_name(name, "Room #{id}"),
         profile: profile,
         frame_ms: frame_ms,
         access: access,
         description: Text.clean(description, Text.max_description()),
         dialin_number: hex32(Enum.at(rest, 0)),
         ptt_jitter_ms: jitter(Enum.at(rest, 1)),
         flags: int_or_zero(Enum.at(rest, 2))
       }}
    else
      {:error, {:unknown_profile, profile}}
    end
  end

  def from_wire(record), do: {:error, {:bad_channel, record}}

  def ptt?(%__MODULE__{ptt_jitter_ms: j}), do: j > 0
  def broadcast?(%__MODULE__{flags: f}), do: (f &&& @room_broadcast) != 0
  def music?(%__MODULE__{profile: p} = c), do: broadcast?(c) or String.starts_with?(p, "music-")
  def locked?(%__MODULE__{access: a}), do: a != 0
  def requires_identity?(%__MODULE__{access: a}), do: (a &&& @access_identity) != 0
  def requires_allowlist?(%__MODULE__{access: a}), do: (a &&& @access_allowlist) != 0
  def requires_password?(%__MODULE__{access: a}), do: (a &&& @access_password) != 0

  defp hex32(s) when is_binary(s) and byte_size(s) == 32, do: s
  defp hex32(_), do: nil

  defp jitter(j) when is_integer(j), do: j |> max(0) |> min(@max_jitter_ms)
  defp jitter(_), do: 0

  defp int_or_zero(i) when is_integer(i), do: i
  defp int_or_zero(_), do: 0
end

defmodule Partyline.Protocol.User do
  @moduledoc """
  FIELD_USER record (server to client):

      [member_id, name, identity_hex, room_id, muted, deaf, hops, rtt_ms,
       operator, server_muted, text_only, can_speak]

  The first six are required; the rest default as in the reference
  client (`can_speak` defaults to true).
  """

  alias Partyline.Protocol.Text

  @enforce_keys [:id, :name]
  defstruct [
    :id,
    :name,
    identity: nil,
    room: nil,
    muted: false,
    deaf: false,
    hops: nil,
    rtt: nil,
    operator: false,
    server_muted: false,
    text_only: false,
    speaker: true
  ]

  @type t :: %__MODULE__{}

  @spec to_wire(t()) :: list()
  def to_wire(%__MODULE__{} = u) do
    [
      u.id,
      u.name,
      u.identity,
      u.room,
      u.muted,
      u.deaf,
      u.hops,
      u.rtt,
      u.operator,
      u.server_muted,
      u.text_only,
      u.speaker
    ]
  end

  @doc "Client-side read, as in partyline `Client.user`."
  @spec from_wire(term()) :: {:ok, t()} | {:error, term()}
  def from_wire([id, name, identity, room, muted, deaf | extras]) when is_integer(id) do
    [hops, rtt, operator, server_muted, text_only, speaker] =
      Enum.take(extras ++ List.duplicate(nil, 6), 6)

    {:ok,
     %__MODULE__{
       id: id,
       name: Text.clean_name(name, "guest-#{id}"),
       identity: if(is_binary(identity) and byte_size(identity) == 32, do: identity),
       room: if(is_integer(room), do: room),
       muted: Text.truthy?(muted),
       deaf: Text.truthy?(deaf),
       hops: if(is_integer(hops), do: hops),
       rtt: if(is_number(rtt), do: trunc(rtt)),
       operator: Text.truthy?(operator),
       server_muted: Text.truthy?(server_muted),
       text_only: Text.truthy?(text_only),
       speaker: if(speaker == nil, do: true, else: Text.truthy?(speaker))
     }}
  end

  def from_wire(record), do: {:error, {:bad_user, record}}
end

defmodule Partyline.Protocol.Assignment do
  @moduledoc """
  FIELD_ROOM (server to client): the room the client is now in,
  `[room_id, profile, frame_ms, can_speak]`. All-nil with `can_speak`
  true means no room.
  """

  alias Partyline.Protocol.Text

  @enforce_keys [:room_id, :profile, :frame_ms]
  defstruct [:room_id, :profile, :frame_ms, can_speak: true]

  @type t :: %__MODULE__{}

  @spec to_wire(t() | :none) :: list()
  def to_wire(:none), do: [nil, nil, nil, true]
  def to_wire(%__MODULE__{} = a), do: [a.room_id, a.profile, a.frame_ms, a.can_speak]

  @doc """
  Client-side read, as in partyline `Client.room`. A non-integer room id
  means no room; an unknown profile is an error (the reference client
  fails the session on it).
  """
  @spec from_wire(term()) :: {:ok, t() | :none} | {:error, term()}
  def from_wire([room_id, profile, frame_ms | rest]) do
    can_speak =
      case rest do
        [flag | _] -> Text.truthy?(flag)
        [] -> true
      end

    cond do
      not is_integer(room_id) ->
        {:ok, :none}

      not Partyline.Profile.valid_name?(profile) ->
        {:error, {:unknown_profile, profile}}

      not is_integer(frame_ms) ->
        {:error, {:bad_room, [room_id, profile, frame_ms | rest]}}

      true ->
        {:ok,
         %__MODULE__{room_id: room_id, profile: profile, frame_ms: frame_ms, can_speak: can_speak}}
    end
  end

  def from_wire(record), do: {:error, {:bad_room, record}}
end
