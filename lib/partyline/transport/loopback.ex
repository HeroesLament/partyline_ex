defmodule Partyline.Transport.Loopback do
  @moduledoc """
  In-memory transport with the same event contract as
  `Partyline.Transport.RNS`, for testing the protocol layer without a
  Reticulum mesh.

  Semantics mirrored from the RNS adapter:

    * the initiator's owner gets `:established`, the listener's owner
      gets `:incoming`;
    * when the initiator passes an identity, the responder's owner gets
      `:identified` before any `:packet`;
    * packets larger than the link MDU are refused, not fragmented;
    * closing reports `:initiator_closed` or `:destination_closed` to
      both sides, by which side closed;
    * a link is torn down when its owner exits.

  Identities are plain 16-byte identity hashes here. Pass
  `:destination_hash` to `listen/2` for a fixed address; otherwise one
  is generated. `:mdu` (default 431, the RNS default link MDU) can be
  set on the listener and overridden per `open_link/2`.
  """

  @behaviour Partyline.Transport

  alias Partyline.Transport
  alias Partyline.Transport.{Announce, Link, Listener}
  alias Partyline.Transport.Loopback.{Endpoint, Hub}

  @default_mdu 431

  @doc false
  def default_mdu, do: @default_mdu

  @impl Transport
  def open_link(destination_hash, opts) do
    owner = Keyword.get(opts, :owner, self())

    with {:ok, listener} <- Hub.lookup(destination_hash),
         {:ok, %{owner: responder_owner, mdu: listener_mdu}} <- accept_info(listener) do
      mdu = Keyword.get(opts, :mdu, listener_mdu)
      identity_hash = identity_hash(Keyword.get(opts, :identity))

      initiator_info = %{mdu: mdu, rtt: 0.0, hops: 0, destination_hash: destination_hash}
      responder_info = %{mdu: mdu, rtt: 0.0, hops: nil, destination_hash: nil}

      {:ok, initiator} = Endpoint.start(:initiator, owner, mdu, initiator_info)
      {:ok, responder} = Endpoint.start(:responder, responder_owner, mdu, responder_info)

      :ok = Endpoint.connect(initiator, responder)
      :ok = Endpoint.connect(responder, initiator)

      # Responder events first and synchronously, so its owner has
      # :incoming (and :identified) in its mailbox before the initiator
      # can possibly send anything.
      :ok = Endpoint.emit(responder, {:incoming, responder_info})

      if identity_hash do
        :ok = Endpoint.emit(responder, {:identified, identity_hash})
      end

      :ok = Endpoint.emit(initiator, {:established, initiator_info})

      {:ok, %Link{adapter: __MODULE__, pid: initiator}}
    end
  end

  @impl Transport
  def send_packet(%Link{pid: pid}, data), do: call(pid, {:send, data})

  @impl Transport
  def close_link(%Link{pid: pid}) do
    _ = call(pid, :close)
    :ok
  end

  @impl Transport
  def controlling_process(%Link{pid: pid}, new_owner), do: Transport.handover(pid, new_owner)

  @impl Transport
  def link_info(%Link{pid: pid}), do: call(pid, :info)

  @impl Transport
  def listen(identity, opts) do
    owner = Keyword.get(opts, :owner, self())

    destination_hash =
      Keyword.get_lazy(opts, :destination_hash, fn -> :crypto.strong_rand_bytes(16) end)

    listener_opts = [
      owner: owner,
      destination_hash: destination_hash,
      identity_hash: identity_hash(identity),
      app_data: Keyword.get(opts, :app_data, <<>>),
      mdu: Keyword.get(opts, :mdu, @default_mdu)
    ]

    with {:ok, pid} <- __MODULE__.Server.start_link(listener_opts),
         :ok <- Hub.register(destination_hash, pid) do
      listener = %Listener{adapter: __MODULE__, pid: pid, destination_hash: destination_hash}

      if Keyword.get(opts, :announce, true) do
        announce(listener, nil)
      end

      {:ok, listener}
    end
  end

  @impl Transport
  def announce(%Listener{pid: pid}, app_data) do
    case call(pid, {:announce, app_data}) do
      {:ok, %Announce{} = announce} -> Hub.broadcast(announce)
      {:error, _} = error -> error
    end
  end

  @impl Transport
  def stop_listener(%Listener{pid: pid, destination_hash: hash}) do
    # Unregister first so the path is gone when this returns, instead of
    # whenever the hub processes the listener's DOWN.
    :ok = Hub.unregister(hash)
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl Transport
  def subscribe_announces(pid), do: Hub.subscribe(pid)

  @impl Transport
  def request_path(destination_hash, _timeout) do
    if has_path?(destination_hash), do: :ok, else: {:error, :timeout}
  end

  @impl Transport
  def has_path?(destination_hash), do: match?({:ok, _}, Hub.lookup(destination_hash))

  # --------------------------------------------------------------------------

  defp accept_info(listener), do: call(listener, :accept_info)

  defp identity_hash(nil), do: nil
  defp identity_hash(hash) when is_binary(hash) and byte_size(hash) == 16, do: hash

  defp call(pid, msg) do
    GenServer.call(pid, msg)
  catch
    :exit, _ -> {:error, :closed}
  end

  # ==========================================================================
  # Listener process
  # ==========================================================================

  defmodule Server do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:accept_info, _from, state) do
      {:reply, {:ok, %{owner: state.owner, mdu: state.mdu}}, state}
    end

    def handle_call({:announce, app_data}, _from, state) do
      state = if is_binary(app_data), do: %{state | app_data: app_data}, else: state

      announce = %Announce{
        destination_hash: state.destination_hash,
        identity_hash: state.identity_hash,
        hops: 0,
        app_data: state.app_data
      }

      {:reply, {:ok, announce}, state}
    end
  end
end
