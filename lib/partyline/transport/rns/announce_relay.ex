defmodule Partyline.Transport.RNS.AnnounceRelay do
  @moduledoc """
  Forwards `lxst.room` announces to one subscriber.

  Registers itself with `RNS.AnnounceHashStore` for the `lxst.room` name
  hash, translates each `{:announce, destination}` into a
  `Partyline.Transport.Announce`, and deregisters when the subscriber
  exits. The store doesn't monitor its handlers, so the relay owning the
  registration is what keeps dead subscribers out of it.
  """

  alias Partyline.Transport
  alias Partyline.Transport.Announce
  alias Partyline.Transport.RNS, as: Adapter

  @spec start(pid()) :: pid()
  def start(subscriber) when is_pid(subscriber) do
    name_hash = Adapter.name_hash()

    spawn(fn ->
      ref = Process.monitor(subscriber)
      RNS.AnnounceHashStore.add_handler(nil, name_hash, self())
      loop(subscriber, ref, name_hash)
    end)
  end

  defp loop(subscriber, ref, name_hash) do
    receive do
      {:announce, destination} ->
        Transport.emit_announce(subscriber, to_announce(destination))
        loop(subscriber, ref, name_hash)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        RNS.AnnounceHashStore.remove_handler(nil, name_hash, self())

      _other ->
        loop(subscriber, ref, name_hash)
    end
  end

  @doc false
  @spec to_announce(RNS.Destination.t()) :: Announce.t()
  def to_announce(destination) do
    identity = RNS.Destination.identity(destination)

    %Announce{
      destination_hash: RNS.Destination.hash(destination),
      identity_hash: identity && RNS.Identity.hash(identity),
      hops: RNS.Destination.hops(destination),
      app_data: RNS.Destination.app_data(destination) || <<>>
    }
  end
end
