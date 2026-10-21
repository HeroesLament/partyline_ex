defmodule Partyline.Transport do
  @moduledoc """
  Link-layer contract between the Partyline protocol (client and server)
  and whatever carries it.

  The protocol layer never touches `RNS.*` directly. It opens, accepts,
  sends on and closes links through this module, and receives everything
  as plain messages in its mailbox. `Partyline.Transport.RNS` is the
  production adapter over reticulum_ex; `Partyline.Transport.Loopback`
  is an in-memory adapter with identical event semantics, used for
  protocol tests without a mesh.

  Every function here dispatches on the adapter module carried in the
  `Link` or `Listener` struct, so callers hold one opaque value and never
  name the adapter after setup.

  ## Link events

  The owner of a link receives:

      {:partyline_transport, %Link{}, {:established, info}}
      {:partyline_transport, %Link{}, {:incoming, info}}
      {:partyline_transport, %Link{}, {:identified, identity_hash}}
      {:partyline_transport, %Link{}, {:packet, binary}}
      {:partyline_transport, %Link{}, {:closed, reason}}

  `:established` is the initiator side. When an identity was passed to
  `open_link/3`, LINKIDENTIFY has already been sent when this arrives, so
  the first packet the owner sends (HELLO) is ordered after it on the
  wire. Partyline servers rely on that ordering.

  `:incoming` is the responder side: a new link on a listener, delivered
  to the listener's owner.

  `:identified` is responder side only, sent once when the remote
  identifies. If the remote identifies before its first data packet (the
  reference client always does), `:identified` is delivered before that
  packet's `:packet` event.

  `info` is a map:

    * `:mdu` - link MDU in bytes. Outbound packets must not exceed it;
      adapters do not fragment.
    * `:rtt` - round trip time in seconds, or nil
    * `:hops` - hops to the remote destination (initiator side), or nil
    * `:destination_hash` - remote destination hash (initiator side), or nil

  `reason` in `:closed` is `:initiator_closed`, `:destination_closed`,
  `:timeout`, or an adapter-specific term. A local `close_link/1` also
  produces a `:closed` event for the local owner.

  ## Announce events

  A process registered with `subscribe_announces/2` receives

      {:partyline_announce, %Announce{}}

  for every `lxst.room` announce heard. `app_data` is raw; decoding it
  is protocol work, not transport work.
  """

  alias Partyline.Transport.{Announce, Link, Listener}

  @type info :: %{
          mdu: pos_integer(),
          rtt: float() | nil,
          hops: non_neg_integer() | nil,
          destination_hash: binary() | nil
        }

  @type event ::
          {:established, info()}
          | {:incoming, info()}
          | {:identified, binary()}
          | {:packet, binary()}
          | {:closed, term()}

  @type destination_hash :: <<_::128>>

  # ==========================================================================
  # Adapter callbacks
  # ==========================================================================

  @doc """
  Open an outbound link to a `lxst.room` destination.

  Returns immediately with a `Link`; the owner later receives
  `:established` or `:closed`. The destination must already be known
  (see `request_path/3`).

  Options:
    * `:owner` - pid receiving link events (default: caller)
    * `:identity` - local identity to send LINKIDENTIFY with, or nil for
      an anonymous link
  """
  @callback open_link(destination_hash(), keyword()) :: {:ok, Link.t()} | {:error, term()}

  @doc "Send one packet. The payload must fit the link MDU."
  @callback send_packet(Link.t(), binary()) :: :ok | {:error, term()}

  @doc "Tear the link down. The local owner also receives `:closed`."
  @callback close_link(Link.t()) :: :ok

  @doc "Move event delivery for a link to another process."
  @callback controlling_process(Link.t(), pid()) :: :ok | {:error, term()}

  @doc "Current link metadata, same shape as the `info` in events."
  @callback link_info(Link.t()) :: {:ok, info()} | {:error, term()}

  @doc """
  Register a `lxst.room` destination for `identity` and accept links on it.

  Incoming links are reported to the owner as `:incoming` events.

  Options:
    * `:owner` - pid receiving `:incoming` events (default: caller)
    * `:app_data` - announce app_data (default: empty)
    * `:announce` - announce on start (default: true)
    * `:announce_interval` - re-announce period in ms, or nil to disable
      (default: 3_300_000, matching the reference server)
  """
  @callback listen(identity :: term(), keyword()) :: {:ok, Listener.t()} | {:error, term()}

  @doc "Announce now. A non-nil `app_data` replaces the listener's app_data first."
  @callback announce(Listener.t(), app_data :: binary() | nil) :: :ok | {:error, term()}

  @doc "Stop listening. Existing links are not affected."
  @callback stop_listener(Listener.t()) :: :ok

  @doc "Deliver `lxst.room` announces to `pid` until it exits."
  @callback subscribe_announces(pid()) :: :ok

  @doc """
  Make sure a path to `destination_hash` is known, requesting one if
  needed. Blocks the caller up to `timeout` ms; call it from a task, not
  from a process that must stay responsive.
  """
  @callback request_path(destination_hash(), timeout()) :: :ok | {:error, term()}

  @doc "Whether a path to `destination_hash` is currently known."
  @callback has_path?(destination_hash()) :: boolean()

  # ==========================================================================
  # Facade
  # ==========================================================================

  @doc "Open a link through `adapter`. See `c:open_link/2`."
  @spec open_link(module(), destination_hash(), keyword()) :: {:ok, Link.t()} | {:error, term()}
  def open_link(adapter, destination_hash, opts \\ []) do
    adapter.open_link(destination_hash, Keyword.put_new(opts, :owner, self()))
  end

  @spec send_packet(Link.t(), binary()) :: :ok | {:error, term()}
  def send_packet(%Link{adapter: adapter} = link, data) when is_binary(data) do
    adapter.send_packet(link, data)
  end

  @spec close_link(Link.t()) :: :ok
  def close_link(%Link{adapter: adapter} = link), do: adapter.close_link(link)

  @spec controlling_process(Link.t(), pid()) :: :ok | {:error, term()}
  def controlling_process(%Link{adapter: adapter} = link, pid) when is_pid(pid) do
    adapter.controlling_process(link, pid)
  end

  @spec link_info(Link.t()) :: {:ok, info()} | {:error, term()}
  def link_info(%Link{adapter: adapter} = link), do: adapter.link_info(link)

  @doc "Listen through `adapter`. See `c:listen/2`."
  @spec listen(module(), term(), keyword()) :: {:ok, Listener.t()} | {:error, term()}
  def listen(adapter, identity, opts \\ []) do
    adapter.listen(identity, Keyword.put_new(opts, :owner, self()))
  end

  @spec announce(Listener.t(), binary() | nil) :: :ok | {:error, term()}
  def announce(%Listener{adapter: adapter} = listener, app_data \\ nil) do
    adapter.announce(listener, app_data)
  end

  @spec stop_listener(Listener.t()) :: :ok
  def stop_listener(%Listener{adapter: adapter} = listener), do: adapter.stop_listener(listener)

  @spec subscribe_announces(module(), pid()) :: :ok
  def subscribe_announces(adapter, pid \\ self()), do: adapter.subscribe_announces(pid)

  @spec request_path(module(), destination_hash(), timeout()) :: :ok | {:error, term()}
  def request_path(adapter, destination_hash, timeout \\ 20_000) do
    adapter.request_path(destination_hash, timeout)
  end

  @spec has_path?(module(), destination_hash()) :: boolean()
  def has_path?(adapter, destination_hash), do: adapter.has_path?(destination_hash)

  # ==========================================================================
  # Helpers for adapters
  # ==========================================================================

  @doc false
  # Single place that builds event messages, so every adapter emits the
  # exact same shape.
  @spec emit(pid() | nil, Link.t(), event()) :: :ok
  def emit(nil, _link, _event), do: :ok

  def emit(owner, %Link{} = link, event) when is_pid(owner) do
    send(owner, {:partyline_transport, link, event})
    :ok
  end

  @doc false
  @spec emit_announce(pid(), Announce.t()) :: :ok
  def emit_announce(pid, %Announce{} = announce) do
    send(pid, {:partyline_announce, announce})
    :ok
  end

  @doc false
  # Synchronous owner handover against a process that implements the
  # `{:"$partyline_set_owner", new_owner, caller, tag}` message. Both
  # adapters' per-link processes do.
  @spec handover(pid(), pid(), timeout()) :: :ok | {:error, term()}
  def handover(link_pid, new_owner, timeout \\ 5_000) do
    tag = make_ref()
    mref = Process.monitor(link_pid)
    send(link_pid, {:"$partyline_set_owner", new_owner, self(), tag})

    receive do
      {^tag, :ok} ->
        Process.demonitor(mref, [:flush])
        :ok

      {:DOWN, ^mref, :process, _pid, _reason} ->
        {:error, :closed}
    after
      timeout ->
        Process.demonitor(mref, [:flush])
        {:error, :timeout}
    end
  end
end
