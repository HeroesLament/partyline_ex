defmodule Partyline.Transport.Announce do
  @moduledoc """
  A heard `lxst.room` announce. `app_data` is the raw announce payload.
  """
  @enforce_keys [:destination_hash]
  defstruct [:destination_hash, :identity_hash, :hops, app_data: <<>>]

  @type t :: %__MODULE__{
          destination_hash: binary(),
          identity_hash: binary() | nil,
          hops: non_neg_integer() | nil,
          app_data: binary()
        }
end
