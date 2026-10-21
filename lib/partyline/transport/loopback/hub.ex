defmodule Partyline.Transport.Loopback.Hub do
  @moduledoc false
  # Name service for the loopback transport: destination hash to listener
  # pid, plus announce subscribers. Started on first use, unlinked, so it
  # outlives the test processes that touch it.

  use GenServer

  alias Partyline.Transport

  def lookup(destination_hash), do: call({:lookup, destination_hash})
  def register(destination_hash, pid), do: call({:register, destination_hash, pid})
  def unregister(destination_hash), do: call({:unregister, destination_hash})
  def subscribe(pid), do: call({:subscribe, pid})
  def broadcast(announce), do: call({:broadcast, announce})

  defp call(msg) do
    ensure_started()
    GenServer.call(__MODULE__, msg)
  end

  defp ensure_started do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def init(_), do: {:ok, %{listeners: %{}, subscribers: %{}}}

  @impl true
  def handle_call({:lookup, hash}, _from, state) do
    case Map.fetch(state.listeners, hash) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, {:error, :destination_not_found}, state}
    end
  end

  def handle_call({:register, hash, pid}, _from, state) do
    if Map.has_key?(state.listeners, hash) do
      {:reply, {:error, :destination_in_use}, state}
    else
      Process.monitor(pid)
      {:reply, :ok, put_in(state.listeners[hash], pid)}
    end
  end

  def handle_call({:unregister, hash}, _from, state) do
    {:reply, :ok, %{state | listeners: Map.delete(state.listeners, hash)}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[pid], ref)}
  end

  def handle_call({:broadcast, announce}, _from, state) do
    for pid <- Map.keys(state.subscribers), do: Transport.emit_announce(pid, announce)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    listeners = for {hash, lpid} <- state.listeners, lpid != pid, into: %{}, do: {hash, lpid}
    {:noreply, %{state | listeners: listeners, subscribers: Map.delete(state.subscribers, pid)}}
  end
end
