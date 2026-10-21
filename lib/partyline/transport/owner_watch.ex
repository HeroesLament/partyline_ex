defmodule Partyline.Transport.OwnerWatch do
  @moduledoc false
  # Tears a link down when its owner exits.
  #
  # Per-link processes can't always monitor their owner themselves:
  # RNS.GenLink routes every :DOWN it receives in an active state to its
  # Resource bookkeeping, so a monitor set up inside a GenLink callback
  # module would never reach it. A tiny side process does the watching
  # instead and calls `on_owner_down` when the owner goes away. It also
  # watches the link process so it exits with it.

  @spec start(pid(), pid(), (-> any())) :: pid()
  def start(owner, link_pid, on_owner_down) when is_pid(owner) and is_pid(link_pid) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      link_ref = Process.monitor(link_pid)

      receive do
        {:DOWN, ^owner_ref, :process, _pid, _reason} -> on_owner_down.()
        {:DOWN, ^link_ref, :process, _pid, _reason} -> :ok
        :stop -> :ok
      end
    end)
  end

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(watch) when is_pid(watch) do
    send(watch, :stop)
    :ok
  end
end
