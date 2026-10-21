defmodule Partyline.Transport.LoopbackTest do
  use ExUnit.Case, async: true

  alias Partyline.Transport
  alias Partyline.Transport.{Announce, Link, Listener, Loopback}

  @identity :binary.copy(<<0xAB>>, 16)

  # The test process owns both the listener and the client link, so it
  # sees both sides' events. Tests that need distinct owners spawn one.
  defp listen(opts \\ []) do
    {:ok, listener} = Transport.listen(Loopback, nil, Keyword.put_new(opts, :announce, false))
    listener
  end

  defp connect(listener, opts \\ []) do
    {:ok, client} = Transport.open_link(Loopback, listener.destination_hash, opts)
    assert_receive {:partyline_transport, server, {:incoming, _info}}
    assert_receive {:partyline_transport, ^client, {:established, _info}}
    {client, server}
  end

  test "open and accept report the documented info on each side" do
    listener = listen()
    {:ok, client} = Transport.open_link(Loopback, listener.destination_hash)

    assert_receive {:partyline_transport, %Link{} = server, {:incoming, info}}
    assert info.mdu == 431
    assert info.destination_hash == nil

    assert_receive {:partyline_transport, ^client, {:established, info}}
    assert info.destination_hash == listener.destination_hash
    assert info.hops == 0
    refute client == server
  end

  test "packets flow both ways" do
    {client, server} = connect(listen())

    :ok = Transport.send_packet(client, "hello")
    assert_receive {:partyline_transport, ^server, {:packet, "hello"}}

    :ok = Transport.send_packet(server, "welcome")
    assert_receive {:partyline_transport, ^client, {:packet, "welcome"}}
  end

  test "identified arrives before the first packet" do
    listener = listen()
    {:ok, client} = Transport.open_link(Loopback, listener.destination_hash, identity: @identity)
    assert_receive {:partyline_transport, ^client, {:established, _}}
    :ok = Transport.send_packet(client, "hello")

    assert_receive {:partyline_transport, server, {:incoming, _}}
    assert {:identified, @identity} = next_event(server)
    assert {:packet, "hello"} = next_event(server)
  end

  # Oldest pending event for `link`, in mailbox order.
  defp next_event(link) do
    receive do
      {:partyline_transport, ^link, event} -> event
    after
      1_000 -> flunk("no event for #{inspect(link)}")
    end
  end

  test "anonymous links never identify" do
    {client, server} = connect(listen())
    :ok = Transport.send_packet(client, "x")
    assert_receive {:partyline_transport, ^server, {:packet, "x"}}
    refute_received {:partyline_transport, ^server, {:identified, _}}
  end

  test "packets over the MDU are refused" do
    {client, _server} = connect(listen(mdu: 64))
    assert :ok = Transport.send_packet(client, :binary.copy(<<0>>, 64))
    assert {:error, :too_large} = Transport.send_packet(client, :binary.copy(<<0>>, 65))
  end

  test "initiator close reaches both owners with the same reason" do
    {client, server} = connect(listen())
    :ok = Transport.close_link(client)
    assert_receive {:partyline_transport, ^client, {:closed, :initiator_closed}}
    assert_receive {:partyline_transport, ^server, {:closed, :initiator_closed}}
    assert {:error, :closed} = Transport.send_packet(client, "late")
  end

  test "responder close reports destination_closed" do
    {client, server} = connect(listen())
    :ok = Transport.close_link(server)
    assert_receive {:partyline_transport, ^server, {:closed, :destination_closed}}
    assert_receive {:partyline_transport, ^client, {:closed, :destination_closed}}
  end

  test "a link closes when its owner exits" do
    listener = listen()
    test = self()

    owner =
      spawn(fn ->
        {:ok, link} = Transport.open_link(Loopback, listener.destination_hash)
        send(test, {:link, link})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:link, _client}
    assert_receive {:partyline_transport, server, {:incoming, _}}
    send(owner, :exit)
    assert_receive {:partyline_transport, ^server, {:closed, :initiator_closed}}
  end

  test "controlling_process moves event delivery" do
    {client, server} = connect(listen())
    test = self()

    new_owner =
      spawn(fn ->
        receive do
          {:partyline_transport, _link, event} -> send(test, {:relayed, event})
        end
      end)

    :ok = Transport.controlling_process(server, new_owner)
    :ok = Transport.send_packet(client, "moved")
    assert_receive {:relayed, {:packet, "moved"}}
    refute_received {:partyline_transport, ^server, {:packet, "moved"}}
  end

  test "announces reach subscribers with current app_data" do
    :ok = Transport.subscribe_announces(Loopback)
    listener = listen(app_data: "first")
    hash = listener.destination_hash

    :ok = Transport.announce(listener)
    assert_receive {:partyline_announce, %Announce{destination_hash: ^hash, app_data: "first"}}

    :ok = Transport.announce(listener, "second")
    assert_receive {:partyline_announce, %Announce{destination_hash: ^hash, app_data: "second"}}
  end

  test "paths exist only while a listener is up" do
    %Listener{destination_hash: hash} = listener = listen()
    assert Transport.has_path?(Loopback, hash)
    assert :ok = Transport.request_path(Loopback, hash, 10)

    :ok = Transport.stop_listener(listener)
    refute Transport.has_path?(Loopback, hash)
    assert {:error, :destination_not_found} = Transport.open_link(Loopback, hash)
  end

  test "link_info reports the negotiated MDU" do
    {client, _server} = connect(listen(mdu: 200))
    assert {:ok, %{mdu: 200}} = Transport.link_info(client)
  end
end
