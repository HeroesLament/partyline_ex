defmodule Partyline.Server.Room do
  @moduledoc """
  A server room, built from a room spec the way the reference `Room`
  is (partyline 1.0.5 `server.Room`).

  Spec keys (strings, as in server.json): `name`, `profile`,
  `description`, `password`, `require_identity`, `max_members`, `ptt`,
  `ptt_jitter_ms`, `allow` (identity hex list), `music` (identity hex
  list; makes the room broadcast-only for everyone else).

  Reference quirks kept: an empty `allow` list means no allow list
  (truthiness test), but a present `music` list, even empty, makes the
  room a broadcast room (`is not None` test).
  """

  import Bitwise

  alias Partyline.Profile
  alias Partyline.Protocol.{Channel, Text}

  @access_identity 1
  @access_allowlist 2
  @access_password 4
  @room_broadcast 1
  @ptt_jitter_ms 6_000
  @max_jitter_ms 30_000

  @enforce_keys [:id, :name, :profile, :frame_ms]
  defstruct [
    :id,
    :name,
    :profile,
    :frame_ms,
    :password,
    :allow,
    :music,
    description: "",
    ptt: false,
    ptt_jitter_ms: 0,
    require_identity: false,
    max_members: 32,
    members: MapSet.new(),
    spec: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Build a room. `defaults` carries the server-wide `:profile`,
  `:max_members` and `:require_identity`.
  """
  @spec new(pos_integer(), map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(id, spec, defaults) when is_map(spec) do
    spec = Map.new(spec, fn {k, v} -> {to_string(k), v} end)
    name = Text.clean_name(spec["name"], "Room #{id}")
    profile = spec["profile"] || Keyword.fetch!(defaults, :profile)
    ptt = Text.truthy?(Map.get(spec, "ptt", Map.has_key?(spec, "ptt_jitter_ms")))

    allow_list = if Text.truthy?(spec["allow"]), do: spec["allow"], else: nil

    with {:ok, profile_info} <- profile(profile, name),
         {:ok, jitter} <- jitter(ptt, spec, name),
         {:ok, allow} <- hash_set(allow_list, name, "allow"),
         {:ok, music} <- hash_set(spec["music"], name, "music") do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: Text.clean(spec["description"] || "", Text.max_description()),
         profile: profile,
         frame_ms: profile_info.frame_ms,
         ptt: ptt,
         ptt_jitter_ms: jitter,
         password: nonempty(spec["password"]),
         require_identity:
           Text.truthy?(
             Map.get(spec, "require_identity", Keyword.get(defaults, :require_identity, false))
           ),
         allow: allow,
         music: music,
         max_members: spec["max_members"] || Keyword.get(defaults, :max_members, 32),
         spec: spec
       }}
    end
  end

  defp profile(name, room) do
    case Profile.fetch(name) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, "room #{inspect(room)}: unknown profile #{inspect(name)}"}
    end
  end

  defp jitter(false, _spec, _room), do: {:ok, 0}

  defp jitter(true, spec, room) do
    case Map.get(spec, "ptt_jitter_ms", @ptt_jitter_ms) do
      j when is_integer(j) and j >= 1 and j <= @max_jitter_ms -> {:ok, j}
      _ -> {:error, "room #{inspect(room)}: ptt_jitter_ms must be between 1 and #{@max_jitter_ms}"}
    end
  end

  @doc false
  # nil stays nil; any list (even empty) becomes a set.
  def hash_set(nil, _room, _key), do: {:ok, nil}

  def hash_set(list, room, key) when is_list(list) do
    Enum.reduce_while(list, {:ok, MapSet.new()}, fn hex, {:ok, acc} ->
      case parse_hash(hex) do
        {:ok, hash} -> {:cont, {:ok, MapSet.put(acc, hash)}}
        :error -> {:halt, {:error, "room #{inspect(room)}: bad #{key} entry #{inspect(hex)}"}}
      end
    end)
  end

  def hash_set(other, room, key),
    do: {:error, "room #{inspect(room)}: #{key} must be a list, got #{inspect(other)}"}

  @doc "Parse a 32-hex-char identity hash."
  @spec parse_hash(term()) :: {:ok, binary()} | :error
  def parse_hash(hex) when is_binary(hex) do
    case Base.decode16(String.trim(hex), case: :mixed) do
      {:ok, <<_::binary-size(16)>> = hash} -> {:ok, hash}
      _ -> :error
    end
  end

  def parse_hash(_), do: :error

  @spec broadcast?(t()) :: boolean()
  def broadcast?(%__MODULE__{music: music}), do: music != nil

  @spec access(t()) :: non_neg_integer()
  def access(%__MODULE__{} = room) do
    0
    |> bor_if(room.require_identity or room.allow != nil, @access_identity)
    |> bor_if(room.allow != nil, @access_allowlist)
    |> bor_if(room.password != nil, @access_password)
  end

  @spec flags(t()) :: non_neg_integer()
  def flags(room), do: if(broadcast?(room), do: @room_broadcast, else: 0)

  @spec requires_identity?(t()) :: boolean()
  def requires_identity?(room), do: (access(room) &&& @access_identity) != 0

  @doc """
  Admission check, in reference order. `identity` is the member's
  identity hash or nil. Returns nil when allowed, or the reason text.
  """
  @spec check(t(), binary() | nil, term()) :: String.t() | nil
  def check(%__MODULE__{} = room, identity, password) do
    cond do
      requires_identity?(room) and identity == nil ->
        "room requires an identified user"

      room.allow != nil and not MapSet.member?(room.allow, identity) ->
        "you are not on this room's allow list"

      room.password != nil and not same_password?(password, room.password) ->
        "wrong password"

      MapSet.size(room.members) >= room.max_members ->
        "room is full"

      true ->
        nil
    end
  end

  @spec can_speak?(t(), binary() | nil) :: boolean()
  def can_speak?(%__MODULE__{music: nil}, _identity), do: true
  def can_speak?(_room, nil), do: false
  def can_speak?(%__MODULE__{music: music}, identity), do: MapSet.member?(music, identity)

  @spec to_channel(t(), String.t() | nil) :: Channel.t()
  def to_channel(%__MODULE__{} = room, dialin_number \\ nil) do
    %Channel{
      id: room.id,
      name: room.name,
      profile: room.profile,
      frame_ms: room.frame_ms,
      access: access(room),
      description: room.description,
      dialin_number: dialin_number,
      ptt_jitter_ms: room.ptt_jitter_ms,
      flags: flags(room)
    }
  end

  @doc "Constant-time password comparison; non-strings never match."
  @spec same_password?(term(), term()) :: boolean()
  def same_password?(given, expected) when is_binary(given) and is_binary(expected) do
    byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)
  end

  def same_password?(_, _), do: false

  defp bor_if(acc, true, flag), do: acc ||| flag
  defp bor_if(acc, false, _flag), do: acc

  defp nonempty(s) when is_binary(s) and s != "", do: s
  defp nonempty(_), do: nil
end
