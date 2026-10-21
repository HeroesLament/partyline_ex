defmodule Partyline.Transport.Link do
  @moduledoc """
  Opaque handle for one link. Match on the whole struct to correlate
  events; `pid` is the adapter's per-link process.
  """
  @enforce_keys [:adapter, :pid]
  defstruct [:adapter, :pid]

  @type t :: %__MODULE__{adapter: module(), pid: pid()}
end
