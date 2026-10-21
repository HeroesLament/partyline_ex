defmodule Partyline.Protocol.Text do
  @moduledoc """
  Text sanitizing, matching partyline 1.0.5 `common.clean_text`,
  `clean_name` and `name_key`. Both ends run every received string
  through these, so a compatible peer has to as well.

  Limits are UTF-8 byte counts, not characters.
  """

  @max_name 48
  @max_text 300
  @max_description 120
  @max_announce_description 100
  @max_locale 16

  def max_name, do: @max_name
  def max_text, do: @max_text
  def max_description, do: @max_description
  def max_announce_description, do: @max_announce_description
  def max_locale, do: @max_locale

  # Same character class as common._unprintable.
  @unprintable ~r/[\x{0}-\x{1f}\x{7f}-\x{9f}\x{a0}\x{ad}\x{61c}\x{115f}\x{1160}\x{180e}\x{2007}\x{200b}\x{200e}\x{200f}\x{202a}-\x{202f}\x{2060}-\x{206f}\x{2800}\x{3164}\x{feff}\x{ffa0}]/u

  @doc """
  Strip unprintables, collapse whitespace runs to single spaces, trim,
  and cut to `limit` bytes on a character boundary. Non-strings and
  strings that clean to empty return `fallback`.
  """
  @spec clean(term(), pos_integer(), term()) :: term()
  def clean(text, limit, fallback \\ "")

  def clean(text, limit, fallback) when is_binary(text) do
    if String.valid?(text) do
      text
      |> then(&Regex.replace(@unprintable, &1, ""))
      |> String.split()
      |> Enum.join(" ")
      |> case do
        "" -> fallback
        cleaned -> truncate(cleaned, limit)
      end
    else
      fallback
    end
  end

  def clean(_text, _limit, fallback), do: fallback

  @spec clean_name(term(), term()) :: term()
  def clean_name(name, fallback), do: clean(name, @max_name, fallback)

  @doc "Cut to at most `limit` bytes without splitting a UTF-8 sequence."
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(text, limit) when byte_size(text) <= limit, do: text

  def truncate(text, limit) do
    text
    |> binary_part(0, limit)
    |> drop_partial_tail()
  end

  defp drop_partial_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      drop_partial_tail(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  @doc """
  Comparison key for name uniqueness: NFKC, case folded, format
  characters (Unicode category Cf) removed.
  """
  @spec name_key(String.t()) :: String.t()
  def name_key(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfkc_binary()
    |> :string.casefold()
    |> IO.chardata_to_string()
    |> String.to_charlist()
    |> Enum.reject(&format_char?/1)
    |> List.to_string()
  end

  # Unicode general category Cf.
  @cf_ranges [
    {0x00AD, 0x00AD},
    {0x0600, 0x0605},
    {0x061C, 0x061C},
    {0x06DD, 0x06DD},
    {0x070F, 0x070F},
    {0x0890, 0x0891},
    {0x08E2, 0x08E2},
    {0x180E, 0x180E},
    {0x200B, 0x200F},
    {0x202A, 0x202E},
    {0x2060, 0x2064},
    {0x2066, 0x206F},
    {0xFEFF, 0xFEFF},
    {0xFFF9, 0xFFFB},
    {0x110BD, 0x110BD},
    {0x110CD, 0x110CD},
    {0x13430, 0x1343F},
    {0x1BCA0, 0x1BCA3},
    {0x1D173, 0x1D17A},
    {0xE0001, 0xE0001},
    {0xE0020, 0xE007F}
  ]

  defp format_char?(cp), do: Enum.any?(@cf_ranges, fn {lo, hi} -> cp >= lo and cp <= hi end)

  @doc "Python-style truthiness for wire values that the reference passes through `bool()`."
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?(map) when map == %{}, do: false
  def truthy?(%Msgpax.Bin{data: ""}), do: false
  def truthy?(_), do: true
end
