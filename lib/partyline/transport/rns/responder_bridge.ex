defmodule Partyline.Transport.RNS.ResponderBridge do
  @moduledoc """
  GenLink callback module for links accepted on a Partyline listener.

  ## Identity detection

  `RNS.GenLink` validates an inbound LINKIDENTIFY and stores the peer
  identity on the link record, but it has no callback to tell the
  behaviour module. This bridge recovers the identity from outside:

    1. The first data packet is held back and a helper reads the link
       record with `RNS.GenLink.link/1`. GenLink processes packets in
       arrival order, so a LINKIDENTIFY sent before that packet (the
       reference client sends it right before HELLO) is already applied.
       The helper reports back, `:identified` is emitted if the identity
       is present, and then the held packets are released. The owner
       therefore sees `:identified` before HELLO.
    2. Identities that arrive later are caught by a poll every
       250 ms for 30 s, which covers the reference server's 25 s HELLO
       deadline.

  The proper fix is an optional `handle_remote_identified/2` callback in
  `RNS.GenLink`; when that exists, this module should switch to it.
  """

  use RNS.GenLink

  alias Partyline.Transport
  alias Partyline.Transport.{Link, OwnerWatch}
  alias Partyline.Transport.RNS, as: Adapter

  @poll_ms 250
  @max_polls 120

  defstruct [
    :owner,
    :watch,
    :link,
    :identity_hash,
    phase: :awaiting_first,
    held: [],
    polls: 0
  ]

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    bridge = self()

    state = %__MODULE__{
      owner: owner,
      watch: OwnerWatch.start(owner, bridge, fn -> RNS.GenLink.teardown(bridge) end),
      link: %Link{adapter: Adapter, pid: bridge}
    }

    {:ok, state}
  end

  @impl true
  def handle_link_established(link, state) do
    info = Adapter.info_from_link(link)
    Transport.emit(state.owner, state.link, {:incoming, info})
    Process.send_after(self(), :"$partyline_poll_identity", @poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_message(data, %{phase: :awaiting_first} = state) do
    check_identity(:first)
    {:ok, %{state | phase: :checking, held: [data]}}
  end

  def handle_message(data, %{phase: :checking} = state) do
    {:ok, %{state | held: [data | state.held]}}
  end

  def handle_message(data, %{phase: :open} = state) do
    Transport.emit(state.owner, state.link, {:packet, data})
    {:ok, state}
  end

  @impl true
  def handle_link_closed(reason, state) do
    OwnerWatch.stop(state.watch)
    state = release_held(state)
    Transport.emit(state.owner, state.link, {:closed, reason})
    {:ok, state}
  end

  @impl true
  def handle_info({:"$partyline_identity", tag, result}, state) do
    state = maybe_identified(state, result)

    state =
      if tag == :first and state.phase == :checking do
        release_held(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:"$partyline_poll_identity", state) do
    cond do
      state.identity_hash != nil ->
        {:noreply, state}

      state.polls >= @max_polls ->
        {:noreply, state}

      true ->
        check_identity(:poll)
        Process.send_after(self(), :"$partyline_poll_identity", @poll_ms)
        {:noreply, %{state | polls: state.polls + 1}}
    end
  end

  def handle_info({:"$partyline_set_owner", new_owner, caller, tag}, state) do
    OwnerWatch.stop(state.watch)
    bridge = self()
    watch = OwnerWatch.start(new_owner, bridge, fn -> RNS.GenLink.teardown(bridge) end)
    send(caller, {tag, :ok})
    {:noreply, %{state | owner: new_owner, watch: watch}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --------------------------------------------------------------------------

  # Read the link record from a helper. A call from inside a callback
  # would deadlock the FSM; the helper's call is served right after the
  # current callback returns.
  defp check_identity(tag) do
    bridge = self()

    spawn(fn ->
      result =
        try do
          case RNS.Link.remote_identity(RNS.GenLink.link(bridge)) do
            nil -> :none
            identity -> {:ok, RNS.Identity.hash(identity)}
          end
        catch
          :exit, _ -> :none
        end

      send(bridge, {:"$partyline_identity", tag, result})
    end)
  end

  defp maybe_identified(%{identity_hash: nil} = state, {:ok, hash}) do
    Transport.emit(state.owner, state.link, {:identified, hash})
    %{state | identity_hash: hash}
  end

  defp maybe_identified(state, _result), do: state

  defp release_held(%{held: []} = state), do: %{state | phase: :open}

  defp release_held(state) do
    state.held
    |> Enum.reverse()
    |> Enum.each(&Transport.emit(state.owner, state.link, {:packet, &1}))

    %{state | held: [], phase: :open}
  end
end
