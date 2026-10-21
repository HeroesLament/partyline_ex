defmodule Partyline.Transport.Listener do
  @moduledoc "Opaque handle for a listening `lxst.room` destination."
  @enforce_keys [:adapter, :pid, :destination_hash]
  defstruct [:adapter, :pid, :destination_hash]

  @type t :: %__MODULE__{adapter: module(), pid: pid(), destination_hash: binary()}
end
