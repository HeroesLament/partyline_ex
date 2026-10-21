defmodule Partyline.Transport.RNS do
  @moduledoc """
  Production transport over reticulum_ex.

  ## Process layout

    * One `RNS.GenLink` process per link, running
      `Partyline.Transport.RNS.InitiatorBridge` (outbound) or
      `Partyline.Transport.RNS.ResponderBridge` (accepted). The bridge
      turns GenLink callbacks into `Partyline.Transport` events for the
      link's owner.
    * One `Partyline.Transport.RNS.Listener` per listening destination.
      It owns the `RNS.GenDestination` for `lxst.room` and the
      re-announce timer.
    * One `Partyline.Transport.RNS.AnnounceRelay` per announce
      subscriber.

  ## Prerequisites

  The consuming application starts the RNS runtime and at least one
  interface before using this adapter. Nothing here bootstraps RNS.

  ## Identities

  `:identity` options take an `RNS.Identity` record, or a 16-byte
  identity hash already present in `RNS.IdentityStore`.

  ## Known gaps against the reference

    * Untagged Resource transfers (used by Partyline only for operator
      room configuration) are not supported by `RNS.GenLink` yet: it
      rejects untagged advertisements and has no public send path.
    * `RNS.GenLink` has no callback for a remote LINKIDENTIFY.
      `ResponderBridge` recovers the identity by reading the link record
      from outside the GenLink process. See its moduledoc.
  """

  @behaviour Partyline.Transport

  require Logger

  alias Partyline.Transport
  alias Partyline.Transport.{Link, Listener}
  alias Partyline.Transport.RNS.{AnnounceRelay, InitiatorBridge}
  alias Partyline.Transport.RNS.Listener, as: RNSListener
  alias RNS.Packet.PathRequest

  @app_name "lxst"
  @aspects ["room"]

  @doc "The app name and aspects every Partyline server destination uses."
  @spec destination_name() :: {String.t(), [String.t()]}
  def destination_name, do: {@app_name, @aspects}

  @doc "Truncated name hash of `lxst.room`, used to filter announces."
  @spec name_hash() :: binary()
  def name_hash do
    RNS.Destination.generate_name_hash(Enum.join([@app_name | @aspects], "."))
  end

  # ==========================================================================
  # Outbound links
  # ==========================================================================

  @impl Transport
  def open_link(destination_hash, opts)
      when is_binary(destination_hash) and byte_size(destination_hash) == 16 do
    owner = Keyword.get(opts, :owner, self())

    with {:ok, identity} <- resolve_identity(Keyword.get(opts, :identity)),
         {:ok, pid} <-
           RNS.GenLink.start_link(InitiatorBridge, destination_hash,
             owner: owner,
             identity: identity
           ) do
      {:ok, %Link{adapter: __MODULE__, pid: pid}}
    end
  end

  def open_link(destination_hash, _opts), do: {:error, {:bad_destination_hash, destination_hash}}

  @impl Transport
  def send_packet(%Link{pid: pid}, data) do
    RNS.GenLink.send_data(pid, data)
  catch
    :exit, _ -> {:error, :closed}
  end

  @impl Transport
  def close_link(%Link{pid: pid}) do
    RNS.GenLink.teardown(pid)
    :ok
  end

  @impl Transport
  def controlling_process(%Link{pid: pid}, new_owner), do: Transport.handover(pid, new_owner)

  @impl Transport
  def link_info(%Link{pid: pid}) do
    {:ok, info_from_link(RNS.GenLink.link(pid))}
  catch
    :exit, _ -> {:error, :closed}
  end

  # ==========================================================================
  # Listening
  # ==========================================================================

  @impl Transport
  def listen(identity, opts) do
    opts = Keyword.put_new(opts, :owner, self())

    with {:ok, identity} when identity != nil <- resolve_identity(identity),
         {:ok, pid, hash} <- RNSListener.start(identity, opts) do
      {:ok, %Listener{adapter: __MODULE__, pid: pid, destination_hash: hash}}
    else
      {:ok, nil} -> {:error, :identity_required}
      other -> other
    end
  end

  @impl Transport
  def announce(%Listener{pid: pid}, app_data) do
    GenServer.call(pid, {:announce, app_data})
  catch
    :exit, _ -> {:error, :not_listening}
  end

  @impl Transport
  def stop_listener(%Listener{pid: pid}) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  # ==========================================================================
  # Discovery
  # ==========================================================================

  @impl Transport
  def subscribe_announces(pid) when is_pid(pid) do
    AnnounceRelay.start(pid)
    :ok
  end

  @impl Transport
  def request_path(destination_hash, timeout) do
    if has_path?(destination_hash) do
      :ok
    else
      # wait_request/2 receives in the calling process and matches any
      # {:announce, _} message, so run it in a task to keep the caller's
      # mailbox (which may hold announce relay traffic) untouched.
      task = Task.async(fn -> PathRequest.wait_request(destination_hash, timeout) end)

      case Task.await(task, timeout + 1_000) do
        {:ok, _destination} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Transport
  def has_path?(destination_hash) do
    match?({:ok, _}, RNS.DestinationStore.fetch(destination_hash))
  end

  # ==========================================================================
  # Helpers shared with the bridges
  # ==========================================================================

  @doc false
  @spec info_from_link(RNS.Link.t()) :: Transport.info()
  def info_from_link(link) do
    destination = if RNS.Link.initiator?(link), do: RNS.Link.destination(link), else: nil

    %{
      mdu: RNS.Link.mdu(link),
      rtt: RNS.Link.rtt(link),
      hops: destination && RNS.Destination.hops(destination),
      destination_hash: destination && RNS.Destination.hash(destination)
    }
  end

  @doc false
  @spec resolve_identity(term()) :: {:ok, tuple() | nil} | {:error, term()}
  def resolve_identity(nil), do: {:ok, nil}
  def resolve_identity(identity) when is_tuple(identity), do: {:ok, identity}

  def resolve_identity(hash) when is_binary(hash) and byte_size(hash) == 16 do
    case RNS.IdentityStore.fetch(hash) do
      {:ok, identity} -> {:ok, identity}
      {:error, _} -> {:error, :unknown_identity}
    end
  end

  def resolve_identity(other), do: {:error, {:bad_identity, other}}
end
