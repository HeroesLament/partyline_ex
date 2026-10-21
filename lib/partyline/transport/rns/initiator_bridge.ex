defmodule Partyline.Transport.RNS.InitiatorBridge do
  @moduledoc """
  GenLink callback module for outbound Partyline links.

  On establishment it sends LINKIDENTIFY (when an identity was given) and
  only then reports `:established` to the owner. `RNS.GenLink.identify/2`
  is a call into this same process, so it can't be made from inside
  `handle_link_established/2`; a short-lived helper makes the call and
  reports back. By the time the owner sees `:established`, the identify
  packet has been handed to the interface, so the owner's HELLO follows
  it on the wire.
  """

  use RNS.GenLink

  require Logger

  alias Partyline.Transport
  alias Partyline.Transport.{Link, OwnerWatch}
  alias Partyline.Transport.RNS, as: Adapter

  defstruct [:owner, :watch, :identity, :link]

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    bridge = self()

    state = %__MODULE__{
      owner: owner,
      watch: OwnerWatch.start(owner, bridge, fn -> RNS.GenLink.teardown(bridge) end),
      identity: Keyword.get(opts, :identity),
      link: %Link{adapter: Adapter, pid: bridge}
    }

    {:ok, state}
  end

  @impl true
  def handle_link_established(link, state) do
    info = Adapter.info_from_link(link)
    bridge = self()
    identity = state.identity

    spawn(fn ->
      result = identify(bridge, identity)
      send(bridge, {:"$partyline_established", info, result})
    end)

    {:ok, state}
  end

  @impl true
  def handle_message(data, state) do
    Transport.emit(state.owner, state.link, {:packet, data})
    {:ok, state}
  end

  @impl true
  def handle_link_closed(reason, state) do
    OwnerWatch.stop(state.watch)
    Transport.emit(state.owner, state.link, {:closed, reason})
    {:ok, state}
  end

  @impl true
  def handle_info({:"$partyline_established", info, result}, state) do
    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Partyline.Transport.RNS] LINKIDENTIFY failed: #{inspect(reason)}")
    end

    Transport.emit(state.owner, state.link, {:established, info})
    {:noreply, state}
  end

  def handle_info({:"$partyline_set_owner", new_owner, caller, tag}, state) do
    OwnerWatch.stop(state.watch)
    bridge = self()
    watch = OwnerWatch.start(new_owner, bridge, fn -> RNS.GenLink.teardown(bridge) end)
    send(caller, {tag, :ok})
    {:noreply, %{state | owner: new_owner, watch: watch}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp identify(_bridge, nil), do: :ok

  defp identify(bridge, identity) do
    RNS.GenLink.identify(bridge, identity)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
