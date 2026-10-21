defmodule Partyline.ClientTest do
  use ExUnit.Case, async: true

  alias Partyline.{Client, Protocol, Transport}
  alias Partyline.Protocol.{Assignment, Channel, Hello, User, Welcome}
  alias Partyline.Transport.Loopback

  # The test process plays the server: it owns a loopback listener,
  # receives the client's packets and answers with Protocol-encoded ones.

  @identity :binary.copy(<<0x5A>>, 16)

  @lobby %Channel{id: 1, name: "Lobby", profile: "opus-high", frame_ms: 20, description: "Open"}
  @slow %Channel{id: 2, name: "Slow", profile: "c2-1200", frame_ms: 400, ptt_jitter_ms: 6000}
  @bob %User{id: 2, name: "bob", room: 1}

  setup do
    {:ok, listener} = Transport.listen(Loopback, nil, announce: false)
    %{listener: listener}
  end

  defp start_client(listener, opts \\ []) do
    opts =
      Keyword.merge(
        [adapter: Loopback, destination_hash: listener.destination_hash, name: "alice"],
        opts
      )

    {:ok, client} = Client.start_link(opts)
    assert_receive {:partyline_transport, server, {:incoming, _}}
    {client, server}
  end

  defp from_client(server) do
    assert_receive {:partyline_transport, ^server, {:packet, packet}}
    {:ok, messages} = Protocol.decode_from_client(packet)
    messages
  end

  defp to_client(server, messages) do
    :ok = Transport.send_packet(server, Protocol.encode_to_client(messages))
  end

  # Reference admission sequence: WELCOME, CHANNEL batch, USER batch,
  # SYNCED, ROOM.
  defp admit(server, sid \\ 1) do
    assert [{:hello, %Hello{}}] = from_client(server)
    to_client(server, {:welcome, %Welcome{name: "Srv", sid: sid, motd: "hi", ver: 1, app: "1.0.5"}})
    to_client(server, {:channels, [@lobby, @slow]})
    to_client(server, {:users, [@bob]})
    to_client(server, :synced)
    to_client(server, {:room, %Assignment{room_id: 1, profile: "opus-high", frame_ms: 20}})
  end

  defp event(client, timeout \\ 100) do
    assert_receive {:partyline, ^client, event}, timeout
    event
  end

  test "HELLO carries name, wanted room, state, path metrics and versions", %{listener: l} do
    {_client, server} =
      start_client(l, room: "Slow", password: "pw", muted: true, identity: @identity)

    assert_receive {:partyline_transport, ^server, {:identified, @identity}}

    assert [{:hello, hello}] = from_client(server)

    assert %Hello{
             name: "alice",
             room: "Slow",
             password: "pw",
             muted: true,
             deaf: false,
             text_only: false,
             hops: 0,
             rtt: 0,
             ver: 1,
             app: "1.0.5"
           } = hello
  end

  test "text_only implies muted and deafened", %{listener: l} do
    {_client, server} = start_client(l, text_only: true)
    assert [{:hello, %Hello{text_only: true, muted: true, deaf: true}}] = from_client(server)
  end

  test "admission produces events in reference order and a consistent view", %{listener: l} do
    {client, server} = start_client(l)
    admit(server, 7)

    assert {:connected, %{name: "Srv", sid: 7, motd: "hi", app: "1.0.5"}} = event(client)
    assert {:channel, @lobby} = event(client)
    assert {:channel, @slow} = event(client)
    assert {:user_joined, @bob} = event(client)
    assert :synced = event(client)
    assert {:room, %Assignment{room_id: 1}} = event(client)

    view = Client.info(client)
    assert view.sid == 7
    assert view.room == 1
    assert view.synced
    assert Map.keys(view.channels) == [1, 2]
    assert view.users[2] == @bob
    assert view.mdu == Loopback.default_mdu()
  end

  test "a differing server app version is reported", %{listener: l} do
    {client, server} = start_client(l)
    assert [{:hello, _}] = from_client(server)
    to_client(server, {:welcome, %Welcome{name: "Srv", sid: 1, ver: 1, app: "1.1.0"}})
    assert {:connected, _} = event(client)
    assert {:version, "1.1.0"} = event(client)
  end

  test "member updates: moved, state change, left", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    for _ <- 1..6, do: event(client)

    to_client(server, {:user, %{@bob | room: 2}})
    assert {:user_moved, %User{room: 2}, 1} = event(client)

    to_client(server, {:user, %{@bob | room: 2, muted: true}})
    assert {:user_state, %User{muted: true}, %User{muted: false}} = event(client)

    to_client(server, {:user_left, 2})
    assert {:user_left, %User{id: 2}} = event(client)
    assert Client.info(client).users == %{}
  end

  test "chat: needs a room, is sanitized, and incoming text resolves the sender", %{listener: l} do
    {client, server} = start_client(l)
    assert [{:hello, _}] = from_client(server)
    to_client(server, {:welcome, %Welcome{name: "Srv", sid: 1, ver: 1, app: "1.0.5"}})
    assert {:connected, _} = event(client)

    assert {:error, :no_room} = Client.send_text(client, "too early")

    to_client(server, [
      {:users, [@bob]},
      {:room, %Assignment{room_id: 1, profile: "opus-high", frame_ms: 20}}
    ])

    assert {:user_joined, _} = event(client)
    assert {:room, _} = event(client)

    assert :ok = Client.send_text(client, "  hello\0  world ")
    assert [{:text, "hello world"}] = from_client(server)

    to_client(server, {:text, 2, "hey alice"})
    assert {:text, @bob, 2, "hey alice"} = event(client)
  end

  test "control messages go out as the reference encodes them", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    for _ <- 1..6, do: event(client)

    :ok = Client.move(client, 2, "pw")
    assert [{:move, 2, "pw"}] = from_client(server)

    :ok = Client.set_state(client, true, false)
    assert [{:state, true, false}] = from_client(server)

    :ok = Client.poke(client, 2, "")
    assert [{:poke, 2, "poke"}] = from_client(server)

    :ok = Client.admin(client, "mute", 2)
    assert [{:admin, "mute", 2, nil}] = from_client(server)

    :ok = Client.send_frames(client, [<<1, 8>>, <<1, 8>>], 41)
    assert [{:frames, [<<1, 8>>, <<1, 8>>], 41}] = from_client(server)

    :ok = Client.talk_end(client)
    assert [:talk_end] = from_client(server)
  end

  test "relayed audio and talk ends pass through", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    for _ <- 1..6, do: event(client)

    to_client(server, {:frames, 2, [<<1, 8>>], 10})
    assert {:frames, 2, [<<1, 8>>], 10} = event(client)

    to_client(server, {:talk_end, 2})
    assert {:talk_end, 2} = event(client)
  end

  test "room removal and operator config records", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    for _ <- 1..6, do: event(client)

    to_client(server, {:channel_gone, 2})
    assert {:channel_gone, %Channel{id: 2}} = event(client)

    to_client(server, {:config, ["motd", "new\tmotd"]})
    assert {:motd, "newmotd"} = event(client)

    to_client(server, {:config, ["room", 1, %{"name" => "Lobby"}]})
    assert {:room_spec, 1, %{"name" => "Lobby"}} = event(client)
  end

  test "dial-in notifications", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    for _ <- 1..6, do: event(client)

    hex = String.duplicate("ab", 16)
    to_client(server, [{:notice, "call waiting"}, {:dialin, "waiting", hex}])
    assert {:notice, "call waiting"} = event(client)
    assert {:call_waiting, ^hex} = event(client)

    to_client(server, {:dialin, "answered", hex})
    assert {:call_done, ^hex, "answered"} = event(client)
  end

  test "a terminal denial marks the session kicked", %{listener: l} do
    {client, server} = start_client(l)
    assert [{:hello, _}] = from_client(server)

    to_client(server, {:denied, nil, "wrong server password"})
    assert {:denied, nil, "wrong server password"} = event(client)

    :ok = Transport.close_link(server)

    assert {:closed, %{kicked?: true, error: "wrong server password", reason: :destination_closed}} =
             event(client)
  end

  test "a room denial is not terminal", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    for _ <- 1..6, do: event(client)

    to_client(server, {:denied, 2, "room is full"})
    assert {:denied, 2, "room is full"} = event(client)
    assert Process.alive?(client)
  end

  test "protocol version mismatch closes the session", %{listener: l} do
    {client, server} = start_client(l)
    assert [{:hello, _}] = from_client(server)
    ref = Process.monitor(client)

    to_client(server, {:welcome, %Welcome{name: "Srv", sid: 1, ver: 2, app: "2.0.0"}})

    assert {:closed, %{reason: :protocol_version, kicked?: true, error: error}} = event(client)
    assert error =~ "please update"
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}
  end

  test "no WELCOME in time", %{listener: l} do
    {client, server} = start_client(l, welcome_timeout: 50)
    assert [{:hello, _}] = from_client(server)
    # 50 ms state timeout; leave slack for a loaded async run.
    assert {:closed, %{reason: :welcome_timeout}} = event(client, 1_000)
  end

  test "no path to the server" do
    {:ok, client} =
      Client.start_link(adapter: Loopback, destination_hash: :binary.copy(<<0>>, 16), name: "x")

    assert {:closed, %{reason: {:no_path, :timeout}}} = event(client)
  end

  test "disconnect closes the link", %{listener: l} do
    {client, server} = start_client(l)
    admit(server)
    :ok = Client.disconnect(client)
    assert_receive {:partyline_transport, ^server, {:closed, :initiator_closed}}
    assert {:closed, %{reason: :local, kicked?: false}} = wait_closed(client)
  end

  defp wait_closed(client) do
    receive do
      {:partyline, ^client, {:closed, _} = closed} -> closed
      {:partyline, ^client, _other} -> wait_closed(client)
    after
      1_000 -> flunk("no :closed event")
    end
  end

  test "requests before connecting are refused", %{listener: l} do
    {client, _server} = start_client(l)
    assert {:error, :not_connected} = Client.move(client, 2)
    assert {:error, :not_connected} = Client.send_frames(client, [<<1, 8>>], 1)
    # Local state is still accepted and goes out in HELLO / once connected.
    assert :ok = Client.set_state(client, true, true)
  end
end
