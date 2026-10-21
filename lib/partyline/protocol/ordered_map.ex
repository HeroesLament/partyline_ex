defmodule Partyline.Protocol.OrderedMap do
  @moduledoc """
  A msgpack map packed in a fixed key order.

  The reference packs Python dicts, which umsgpack emits in insertion
  order. Msgpax packs Elixir maps in internal map order. Order doesn't
  change meaning, but packing in the reference's order makes encoded
  packets byte-identical to the reference's, so captures from a Python
  peer can be compared directly.
  """

  @enforce_keys [:pairs]
  defstruct [:pairs]

  @type t :: %__MODULE__{pairs: [{term(), term()}]}

  @spec new([{term(), term()}]) :: t()
  def new(pairs) when is_list(pairs), do: %__MODULE__{pairs: pairs}
end

defimpl Msgpax.Packer, for: Partyline.Protocol.OrderedMap do
  import Bitwise

  def pack(%{pairs: pairs}) do
    [
      header(length(pairs))
      | Enum.map(pairs, fn {key, value} ->
          [Msgpax.Packer.pack(key), Msgpax.Packer.pack(value)]
        end)
    ]
  end

  defp header(n) when n < 16, do: <<0x80 ||| n>>
  defp header(n) when n < 0x10000, do: <<0xDE, n::16>>
  defp header(n), do: <<0xDF, n::32>>
end
