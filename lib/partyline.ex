defmodule Partyline do
  @moduledoc """
  Partyline group voice over Reticulum.

  Wire compatible with RFnexus/partyline, protocol version 1 (reference
  app 1.0.5, LXST 0.5.4). Server destinations are `SINGLE` destinations
  named `lxst.room`.

  ## Layers

    * `Partyline.Transport` - link layer contract. Adapters:
      `Partyline.Transport.RNS` over reticulum_ex, and
      `Partyline.Transport.Loopback` in memory for tests.
    * Protocol, client and server: not written yet.
  """

  @protocol_version 1
  @reference_app_version "1.0.5"

  @doc "Partyline protocol version spoken on the wire (HELLO/WELCOME `ver`)."
  def protocol_version, do: @protocol_version

  @doc "Reference application version this implementation tracks."
  def reference_app_version, do: @reference_app_version
end
