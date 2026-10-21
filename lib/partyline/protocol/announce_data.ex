defmodule Partyline.Protocol.AnnounceData do
  @moduledoc """
  Server announce `app_data`: a msgpack array

      [protocol_version, name, flags, description, language, country]

  with trailing empty fields dropped down to a minimum of three elements
  (partyline 1.0.5 `common.pack_announce` / `unpack_announce`). A hidden
  server announces an empty name.
  """

  import Bitwise

  alias Partyline.Protocol.Text

  @hidden 1
  @password 2
  @allowlist 4

  defstruct name: nil, flags: 0, version: nil, description: "", language: "", country: ""

  @type t :: %__MODULE__{
          name: String.t() | nil,
          flags: non_neg_integer(),
          version: integer(),
          description: String.t(),
          language: String.t(),
          country: String.t()
        }

  def flag_hidden, do: @hidden
  def flag_password, do: @password
  def flag_allowlist, do: @allowlist

  @spec hidden?(t()) :: boolean()
  def hidden?(%__MODULE__{flags: f}), do: (f &&& @hidden) != 0

  @spec password?(t()) :: boolean()
  def password?(%__MODULE__{flags: f}), do: (f &&& @password) != 0

  @spec allowlist?(t()) :: boolean()
  def allowlist?(%__MODULE__{flags: f}), do: (f &&& @allowlist) != 0

  @doc "Build announce app_data. `name` should already be cleaned (\"\" when hidden)."
  @spec pack(String.t(), non_neg_integer(), keyword()) :: binary()
  def pack(name, flags \\ 0, opts \\ []) do
    fields = [
      Partyline.protocol_version(),
      name,
      flags,
      Text.clean(Keyword.get(opts, :description, ""), Text.max_announce_description()),
      Text.clean(Keyword.get(opts, :language, ""), Text.max_locale()),
      Text.clean(Keyword.get(opts, :country, ""), Text.max_locale())
    ]

    fields
    |> trim_trailing()
    |> Msgpax.pack!(iodata: false)
  end

  # Drop empty trailing fields while more than three remain.
  defp trim_trailing(fields) do
    fields
    |> Enum.reverse()
    |> do_trim(length(fields))
    |> Enum.reverse()
  end

  defp do_trim([last | rest], len) when len > 3 do
    if Text.truthy?(last), do: [last | rest], else: do_trim(rest, len - 1)
  end

  defp do_trim(reversed, _len), do: reversed

  @doc "Parse announce app_data. Returns :error for anything the reference would reject."
  @spec unpack(binary()) :: {:ok, t()} | :error
  def unpack(app_data) when is_binary(app_data) do
    # binary: true keeps msgpack bin and str distinct, so a bin-typed name
    # is rejected the way the reference's str check rejects bytes.
    case Msgpax.unpack(app_data, binary: true) do
      {:ok, [version, name | rest]} when is_integer(version) ->
        {:ok,
         %__MODULE__{
           version: version,
           name: nil_if_empty(Text.clean_name(name, "")),
           flags: flags(rest),
           description: field(rest, 1, Text.max_announce_description()),
           language: field(rest, 2, Text.max_locale()),
           country: field(rest, 3, Text.max_locale())
         }}

      _ ->
        :error
    end
  end

  def unpack(_), do: :error

  defp flags([flags | _]) when is_integer(flags), do: flags
  defp flags(_), do: 0

  defp field(rest, index, limit), do: Text.clean(Enum.at(rest, index), limit)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(name), do: name
end
