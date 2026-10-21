defmodule Partyline.Transport.RNS.Listener do
  @moduledoc """
  Owns one listening `lxst.room` destination.

  `RNS.GenDestination` accepts the links but offers no way to re-announce
  or change app_data from outside, and its `announce_on_start` builds a
  fresh announce without writing it back to `RNS.DestinationStore`, so
  path requests for the destination would get no answer. This process
  therefore starts the GenDestination with `announce_on_start: false`
  and does all announcing itself: build the announce, broadcast it, and
  store the destination carrying it so `RNS.Packet.PathRequest` can
  answer with it.
  """

  use GenServer

  require Logger
  require RNS.Destination

  alias Partyline.Transport.RNS, as: Adapter
  alias Partyline.Transport.RNS.ResponderBridge

  @default_interval 3_300_000

  defmodule Destination do
    @moduledoc false
    use RNS.GenDestination

    @impl true
    def init(%{owner: owner}), do: {:ok, %{owner: owner}}

    @impl true
    def handle_data(_data, _source, state), do: {:ok, state}

    @impl true
    def handle_link_request(_packet, state) do
      {:accept, ResponderBridge, [owner: state.owner], state}
    end
  end

  @doc false
  @spec start(tuple(), keyword()) :: {:ok, pid(), binary()} | {:error, term()}
  def start(identity, opts) do
    case GenServer.start_link(__MODULE__, {identity, opts}) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :destination_hash)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ==========================================================================
  # GenServer
  # ==========================================================================

  @impl true
  def init({identity, opts}) do
    Process.flag(:trap_exit, true)

    owner = Keyword.fetch!(opts, :owner)
    {app_name, aspects} = Adapter.destination_name()

    destination =
      RNS.Destination.new(
        app_name: app_name,
        aspects: aspects,
        type: :single,
        identity: identity,
        app_data: Keyword.get(opts, :app_data, <<>>)
      )

    hash = RNS.Destination.hash(destination)

    case RNS.GenDestination.start_link(Destination, destination, %{owner: owner},
           announce_on_start: false
         ) do
      {:ok, gen_destination} ->
        state = %{
          hash: hash,
          gen_destination: gen_destination,
          interval: Keyword.get(opts, :announce_interval, @default_interval)
        }

        if Keyword.get(opts, :announce, true) do
          send(self(), :announce)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:destination_hash, _from, state), do: {:reply, state.hash, state}

  def handle_call({:announce, app_data}, _from, state) do
    {:reply, do_announce(state.hash, app_data), state}
  end

  @impl true
  def handle_info(:announce, state) do
    case do_announce(state.hash, nil) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Partyline.Transport.RNS] announce failed: #{inspect(reason)}")
    end

    if is_integer(state.interval) do
      Process.send_after(self(), :announce, state.interval)
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{gen_destination: pid} = state) do
    {:stop, {:gen_destination_exited, reason}, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.gen_destination) do
      GenServer.stop(state.gen_destination, :normal)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # ==========================================================================
  # Announcing
  # ==========================================================================

  # The store copy is the one GenDestination registered, with its virtual
  # interface attached. Always start from it.
  defp do_announce(hash, app_data) do
    with {:ok, destination} <- RNS.DestinationStore.fetch(hash) do
      destination =
        if is_binary(app_data) do
          RNS.Destination.destination(destination, app_data: app_data)
        else
          destination
        end

      case RNS.Destination.broadcast_announce(destination, update_announce: true) do
        {:error, reason} ->
          {:error, reason}

        announced ->
          RNS.DestinationStore.put(announced)
          :ok
      end
    end
  end
end
