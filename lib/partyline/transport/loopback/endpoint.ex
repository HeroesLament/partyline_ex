defmodule Partyline.Transport.Loopback.Endpoint do
  @moduledoc false
  # One side of a loopback link. Holds the owner, the peer endpoint and
  # the MDU; relays packets to the peer and events to the owner.

  use GenServer

  alias Partyline.Transport
  alias Partyline.Transport.Link

  def start(role, owner, mdu, info) do
    GenServer.start(__MODULE__, %{role: role, owner: owner, mdu: mdu, info: info})
  end

  def connect(endpoint, peer), do: GenServer.call(endpoint, {:connect, peer})
  def emit(endpoint, event), do: GenServer.call(endpoint, {:emit, event})

  @impl true
  def init(state) do
    state =
      Map.merge(state, %{
        link: %Link{adapter: Partyline.Transport.Loopback, pid: self()},
        owner_ref: Process.monitor(state.owner),
        peer: nil,
        peer_ref: nil
      })

    {:ok, state}
  end

  @impl true
  def handle_call({:connect, peer}, _from, state) do
    {:reply, :ok, %{state | peer: peer, peer_ref: Process.monitor(peer)}}
  end

  def handle_call({:emit, event}, _from, state) do
    Transport.emit(state.owner, state.link, event)
    {:reply, :ok, state}
  end

  def handle_call({:send, data}, _from, state) when is_binary(data) do
    cond do
      state.peer == nil ->
        {:reply, {:error, :not_established}, state}

      byte_size(data) > state.mdu ->
        {:reply, {:error, :too_large}, state}

      true ->
        send(state.peer, {:deliver, data})
        {:reply, :ok, state}
    end
  end

  def handle_call(:info, _from, state), do: {:reply, {:ok, state.info}, state}

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, close(state)}
  end

  @impl true
  def handle_info({:deliver, data}, state) do
    Transport.emit(state.owner, state.link, {:packet, data})
    {:noreply, state}
  end

  def handle_info({:peer_closed, reason}, state) do
    Transport.emit(state.owner, state.link, {:closed, reason})
    {:stop, :normal, state}
  end

  def handle_info({:"$partyline_set_owner", new_owner, caller, tag}, state) do
    Process.demonitor(state.owner_ref, [:flush])
    send(caller, {tag, :ok})
    {:noreply, %{state | owner: new_owner, owner_ref: Process.monitor(new_owner)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, close(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{peer_ref: ref} = state) do
    Transport.emit(state.owner, state.link, {:closed, :timeout})
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Same reason on both sides, chosen by which side closed, as in GenLink.
  defp close(state) do
    reason = if state.role == :initiator, do: :initiator_closed, else: :destination_closed

    if state.peer do
      Process.demonitor(state.peer_ref, [:flush])
      send(state.peer, {:peer_closed, reason})
    end

    Transport.emit(state.owner, state.link, {:closed, reason})
    %{state | peer: nil}
  end
end
