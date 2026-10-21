defmodule Partyline.ServerTest do
  use ExUnit.Case, async: true

  alias Partyline.{Client, Protocol, Server, Transport}
  alias Partyline.Protocol.{Assignment, Hello, User}
  alias Partyline.Transport.Loopback

  # Real Client against real Server over the loopback transport. Raw links
  # (the test process speaking Protocol directly) cover what a well-behaved
  # client can't send.

  @alice :binary.copy(<<0xA1>>, 16)
  @bob :binary.copy(<<0xB0>>, 16)
  @carol :binary.copy(<<0xC4>>, 16)

  @c2_700_frame <<2, 0x00>> <> :binary.copy(<<0x55>>, 40)

  defp hex(hash), do: Base.encode16(hash, case: :lower)

  defp rooms do
    [
      %{"name" => "Lobby", "profile" => "c2-700"},
      %{"name" => "Private", "password" => "hunter2"},
      %{"name" => "Ids", "require_identity" => true},
      %{"name" => "Broadcast", "profile" => "c2-700", "music" => [hex(@alice)]}
    ]
  end

  defp start_server(opts \\ []) do
    opts =
      Keyword.merge(
        [
          adapter: Loopback,
          identity: :crypto.strong_rand_bytes(16),
          name: "Test server",
          rooms: rooms()
        ],
        opts
      )

    server = start_supervised!({Server, opts}, id: make_ref())
    {server, Server.destination_hash(server)}
  end

  defp start_client(hash, name, opts \\ []) do
    {:ok, client} =
      Client.start_link(
        Keyword.merge([adapter: Loopback, destination_hash: hash, name: name], opts)
      )

    client
  end

  # Discard a client's events until `fun` matches one; return it.
  defp wait_for(client, fun, timeout \\ 1_000) do
    receive do
      {:partyline, ^client, event} ->
        if fun.(event), do: event, else: wait_for(client, fun, timeout)
    after
      timeout -> flunk("no matching event from #{inspect(client)}")
    end
  end

  defp joined(hash, name, opts \\ []) do
    client = start_client(hash, name, opts)
    wait_for(client, &match?({:room, _}, &1), Keyword.get(opts, :wait, 1_000))
    client
  end

  defp raw_link(hash, opts \\ []) do
    {:ok, link} = Transport.open_link(Loopback, hash, opts)
    assert_receive {:partyline_transport, ^link, {:established, _}}
    link
  end

  defp raw_hello(link, fields \\ []) do
    hello = struct!(%Hello{name: "raw", ver: 1, app: "1.0.5"}, fields)
    :ok = Transport.send_packet(link, Protocol.encode_to_server({:hello, hello}))
  end

  # Collect decoded server messages on a raw link until `fun` matches one.
  defp raw_wait(link, fun, timeout \\ 1_000) do
    receive do
      {:partyline_transport, ^link, {:packet, packet}} ->
        {:ok, messages} = Protocol.decode_from_server(packet)

        case Enum.find(messages, fun) do
          nil -> raw_wait(link, fun, timeout)
          message -> message
        end
    after
      timeout -> flunk("no matching message on #{inspect(link)}")
    end
  end

  describe "admission" do
    test "join sync and default room" do
      {server, hash} = start_server(motd: "welcome")
      client = start_client(hash, "alice")

      assert {:connected, %{name: "Test server", motd: "welcome", sid: sid}} =
               wait_for(client, &match?({:connected, _}, &1))

      assert :synced = wait_for(client, &(&1 == :synced))

      assert {:room, %Assignment{room_id: 1, profile: "c2-700", frame_ms: 400, can_speak: true}} =
               wait_for(client, &match?({:room, _}, &1))

      view = Client.info(client)
      assert Map.keys(view.channels) == [1, 2, 3, 4]
      assert [%User{id: ^sid, name: "alice", room: 1}] = Server.members(server)
    end

    test "channel records carry access flags and broadcast flag" do
      {_server, hash} = start_server()
      client = joined(hash, "alice")
      channels = Client.info(client).channels

      assert channels[1].access == 0
      assert channels[2].access == 4
      assert channels[3].access == 1
      assert channels[4].flags == 1
    end

    test "members see each other join and leave" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")

      assert {:user_joined, %User{name: "bob"}} =
               wait_for(alice, &match?({:user_joined, %User{name: "bob"}}, &1))

      assert Enum.any?(Map.values(Client.info(bob).users), &(&1.name == "alice"))

      :ok = Client.disconnect(bob)
      assert {:user_left, %User{name: "bob"}} = wait_for(alice, &match?({:user_left, _}, &1))
    end

    test "duplicate names get a numeric suffix, case and width folded" do
      {server, hash} = start_server()
      joined(hash, "bob")
      joined(hash, "BOB")
      joined(hash, "ｂｏｂ")

      names = server |> Server.members() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["BOB (2)", "bob", "ｂｏｂ (3)"]
    end

    test "requested room by name, with a wrong password, falls back to the lobby" do
      {_server, hash} = start_server()
      client = start_client(hash, "alice", identity: @alice, room: "private", password: "nope")

      assert {:denied, 2, "wrong password"} = wait_for(client, &match?({:denied, _, _}, &1))
      assert {:room, %Assignment{room_id: 1}} = wait_for(client, &match?({:room, _}, &1))
    end

    test "requested room with the right password" do
      {_server, hash} = start_server()
      client = start_client(hash, "alice", identity: @alice, room: 2, password: "hunter2")
      assert {:room, %Assignment{room_id: 2}} = wait_for(client, &match?({:room, _}, &1))
    end

    test "unknown room gets a notice and the lobby" do
      {_server, hash} = start_server()
      client = start_client(hash, "alice", room: "Nowhere")
      assert {:notice, "no such room Nowhere"} = wait_for(client, &match?({:notice, _}, &1))
      assert {:room, %Assignment{room_id: 1}} = wait_for(client, &match?({:room, _}, &1))
    end

    test "server password: wrong is terminal, right is admitted" do
      {_server, hash} = start_server(password: "letmein")

      bad = start_client(hash, "alice", identity: @alice, server_password: "nope")
      assert {:denied, nil, "wrong server password"} = wait_for(bad, &match?({:denied, _, _}, &1))
      assert {:closed, %{kicked?: true}} = wait_for(bad, &match?({:closed, _}, &1), 2_000)

      good = start_client(hash, "bob", identity: @bob, server_password: "letmein")
      assert {:room, _} = wait_for(good, &match?({:room, _}, &1))
    end

    test "server allow list" do
      {_server, hash} = start_server(allow: [hex(@alice)])

      bob = start_client(hash, "bob", identity: @bob)

      assert {:denied, nil, "you are not on this server's allow list"} =
               wait_for(bob, &match?({:denied, _, _}, &1))

      assert {:room, _} =
               wait_for(start_client(hash, "alice", identity: @alice), &match?({:room, _}, &1))
    end

    test "anonymous user asking for an identity room waits out the grace, then gets the lobby" do
      {_server, hash} = start_server()
      client = start_client(hash, "anon", room: "Ids")

      assert {:denied, 3, "room requires an identified user"} =
               wait_for(client, &match?({:denied, _, _}, &1), 3_000)

      assert {:room, %Assignment{room_id: 1}} = wait_for(client, &match?({:room, _}, &1))
    end

    test "a second session with the same identity replaces the first" do
      {server, hash} = start_server()
      first = joined(hash, "alice", identity: @alice)
      _second = joined(hash, "alice", identity: @alice)

      assert {:closed, _} = wait_for(first, &match?({:closed, _}, &1))
      assert [%User{name: "alice"}] = Server.members(server)
    end

    test "protocol version mismatch is refused" do
      {_server, hash} = start_server()
      link = raw_link(hash)
      raw_hello(link, ver: 2)

      assert {:denied, nil, reason} = raw_wait(link, &match?({:denied, _, _}, &1))
      assert reason =~ "speaks Partyline protocol 1"
      assert_receive {:partyline_transport, ^link, {:closed, :destination_closed}}, 2_000
    end

    test "only the first HELLO counts" do
      {server, hash} = start_server()
      link = raw_link(hash)
      raw_hello(link, name: "first")
      raw_wait(link, &(&1 == :synced))
      raw_hello(link, name: "second")

      Process.sleep(50)
      assert [%User{name: "first"}] = Server.members(server)
    end
  end

  describe "chat and state" do
    test "text goes to the rest of the room, not the sender" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")

      :ok = Client.send_text(alice, "hello bob")

      assert {:text, %User{name: "alice"}, _, "hello bob"} =
               wait_for(bob, &match?({:text, _, _, _}, &1))

      refute_received {:partyline, ^alice, {:text, _, _, _}}
    end

    test "text does not cross rooms" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice", identity: @alice)
      bob = joined(hash, "bob", identity: @bob, room: 3)

      :ok = Client.send_text(alice, "lobby only")
      Process.sleep(50)
      refute_received {:partyline, ^bob, {:text, _, _, _}}
    end

    test "poke reaches only the target" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")
      bob_id = Client.info(bob).sid

      :ok = Client.poke(alice, bob_id, "wake up")

      assert {:poke, %User{name: "alice"}, _, "wake up"} =
               wait_for(bob, &match?({:poke, _, _, _}, &1))
    end

    test "mute and deafen state is broadcast" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")

      :ok = Client.set_state(bob, true, false)

      assert {:user_state, %User{name: "bob", muted: true}, _} =
               wait_for(alice, &match?({:user_state, %User{name: "bob", muted: true}, _}, &1))
    end

    test "moving rooms" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob", identity: @bob)

      :ok = Client.move(bob, 2, "wrong")
      assert {:denied, 2, "wrong password"} = wait_for(bob, &match?({:denied, _, _}, &1))

      :ok = Client.move(bob, 2, "hunter2")
      assert {:room, %Assignment{room_id: 2}} = wait_for(bob, &match?({:room, _}, &1))

      assert {:user_moved, %User{name: "bob"}, 1} =
               wait_for(alice, &match?({:user_moved, _, _}, &1))

      :ok = Client.move(bob, 99)
      assert {:denied, 99, "no such room"} = wait_for(bob, &match?({:denied, _, _}, &1))
    end
  end

  describe "audio relay" do
    test "valid frames reach the room with speaker and sequence" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")
      alice_id = Client.info(alice).sid

      :ok = Client.send_frames(alice, [@c2_700_frame], 7)

      assert {:frames, ^alice_id, [@c2_700_frame], 7} =
               wait_for(bob, &match?({:frames, _, _, _}, &1))

      :ok = Client.talk_end(alice)
      assert {:talk_end, ^alice_id} = wait_for(bob, &match?({:talk_end, _}, &1))
    end

    test "frames that don't fit the room profile are dropped" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")

      # 2400 bps, 10 frames = 200 ms in a 400 ms room. (The reference only
      # checks codec byte and duration, so a 1200 bps payload of 400 ms
      # would pass in a 700 bps room; see the next test.)
      :ok = Client.send_frames(alice, [<<2, 0x05>> <> :binary.copy(<<0>>, 60)], 1)
      # one good, one bad: the whole batch is dropped
      :ok = Client.send_frames(alice, [@c2_700_frame, <<2, 0x00, 1>>], 2)

      Process.sleep(50)
      refute_received {:partyline, ^bob, {:frames, _, _, _}}
    end

    test "reference quirk: another Codec2 mode with the same duration passes" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")

      c2_1200 = <<2, 0x01>> <> :binary.copy(<<0>>, 60)
      :ok = Client.send_frames(alice, [c2_1200], 1)
      assert {:frames, _, [^c2_1200], 1} = wait_for(bob, &match?({:frames, _, _, _}, &1))
    end

    test "deafened members are skipped" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")
      :ok = Client.set_state(bob, false, true)
      wait_for(alice, &match?({:user_state, %User{deaf: true}, _}, &1))

      :ok = Client.send_frames(alice, [@c2_700_frame], 1)
      Process.sleep(50)
      refute_received {:partyline, ^bob, {:frames, _, _, _}}
    end

    test "broadcast rooms only relay listed speakers" do
      {_server, hash} = start_server()
      alice = start_client(hash, "alice", identity: @alice, room: 4)
      bob = start_client(hash, "bob", identity: @bob, room: 4)

      assert {:room, %Assignment{room_id: 4, can_speak: true}} =
               wait_for(alice, &match?({:room, _}, &1))

      assert {:room, %Assignment{room_id: 4, can_speak: false}} =
               wait_for(bob, &match?({:room, _}, &1))

      :ok = Client.send_frames(bob, [@c2_700_frame], 1)
      Process.sleep(50)
      refute_received {:partyline, ^alice, {:frames, _, _, _}}

      :ok = Client.send_frames(alice, [@c2_700_frame], 1)
      assert {:frames, _, _, 1} = wait_for(bob, &match?({:frames, _, _, _}, &1))
    end

    test "a batch too big for a listener's MDU is split with sequence offsets" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")

      listener = raw_link(hash, mdu: 120)
      raw_hello(listener)
      raw_wait(listener, &match?({:room, _}, &1))

      batch = List.duplicate(@c2_700_frame, 4)
      :ok = Client.send_frames(alice, batch, 65_534)

      chunks =
        for _ <- 1..2 do
          {:frames, _speaker, frames, seq} = raw_wait(listener, &match?({:frames, _, _, _}, &1))
          {length(frames), seq}
        end

      assert chunks == [{2, 65_534}, {2, 0}]
    end

    test "frame rate is limited per member" do
      {_server, hash} = start_server()
      alice = joined(hash, "alice")
      bob = joined(hash, "bob")

      # c2-700: rate 5 frames/s, capacity 64. 70 frames in one go: the
      # first 64 pass, the rest are rate limited.
      for seq <- 1..70, do: :ok = Client.send_frames(alice, [@c2_700_frame], seq)

      received =
        Stream.repeatedly(fn ->
          receive do
            {:partyline, ^bob, {:frames, _, _, seq}} -> seq
          after
            200 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      assert length(received) == 64
    end
  end

  describe "operators" do
    test "kick, and non-operators are refused" do
      {_server, hash} = start_server(ops: [hex(@alice)])
      alice = joined(hash, "alice", identity: @alice)
      bob = joined(hash, "bob", identity: @bob)
      alice_id = Client.info(alice).sid
      bob_id = Client.info(bob).sid

      :ok = Client.admin(bob, "kick", alice_id)
      assert {:notice, "operators only"} = wait_for(bob, &match?({:notice, _}, &1))

      :ok = Client.admin(alice, "kick", bob_id)
      assert {:denied, nil, "kicked by alice"} = wait_for(bob, &match?({:denied, _, _}, &1))
      assert {:closed, %{kicked?: true}} = wait_for(bob, &match?({:closed, _}, &1), 2_000)
    end

    test "ban persists to the state dir and keeps the identity out" do
      dir = Path.join(System.tmp_dir!(), "partyline_ban_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      {_server, hash} = start_server(ops: [hex(@alice)], state_dir: dir)
      alice = joined(hash, "alice", identity: @alice)
      bob = joined(hash, "bob", identity: @bob)

      :ok = Client.admin(alice, "ban", Client.info(bob).sid)
      assert {:denied, nil, "banned by alice"} = wait_for(bob, &match?({:denied, _, _}, &1))
      assert File.read!(Path.join(dir, "banned.txt")) == hex(@bob) <> "\n"

      again = start_client(hash, "bob", identity: @bob)

      assert {:denied, nil, "you are banned from this server"} =
               wait_for(again, &match?({:denied, _, _}, &1))
    end

    test "server mute blocks relay; op promotion is announced" do
      {_server, hash} = start_server(ops: [hex(@alice)])
      alice = joined(hash, "alice", identity: @alice)
      bob = joined(hash, "bob", identity: @bob)
      carol = joined(hash, "carol", identity: @carol)
      bob_id = Client.info(bob).sid

      :ok = Client.admin(alice, "mute", bob_id)

      assert {:notice, "You were muted by operator alice."} =
               wait_for(bob, &match?({:notice, _}, &1))

      :ok = Client.send_frames(bob, [@c2_700_frame], 1)
      Process.sleep(50)
      refute_received {:partyline, ^carol, {:frames, _, _, _}}

      :ok = Client.admin(alice, "op", bob_id)

      assert {:user_state, %User{name: "bob", operator: true}, _} =
               wait_for(carol, &match?({:user_state, %User{operator: true}, _}, &1))
    end

    test "operator move bypasses the room password" do
      {_server, hash} = start_server(ops: [hex(@alice)])
      alice = joined(hash, "alice", identity: @alice)
      bob = joined(hash, "bob", identity: @bob)

      :ok = Client.admin(alice, "move", Client.info(bob).sid, 2)
      assert {:room, %Assignment{room_id: 2}} = wait_for(bob, &match?({:room, _}, &1))

      assert {:notice, "You were moved to Private by operator alice."} =
               wait_for(bob, &match?({:notice, _}, &1))
    end

    test "MOTD change reaches everyone" do
      {_server, hash} = start_server(ops: [hex(@alice)])
      alice = joined(hash, "alice", identity: @alice)
      bob = joined(hash, "bob")

      :ok = Client.configure(alice, "motd", "new motd")
      assert {:motd, "new motd"} = wait_for(bob, &match?({:motd, _}, &1))
    end
  end

  test "dial-in requests get the no-dial-in notice" do
    {_server, hash} = start_server()
    alice = joined(hash, "alice")
    :ok = Client.dialin(alice, "list")
    assert {:notice, "this server has no dial-in"} = wait_for(alice, &match?({:notice, _}, &1))
  end

  test "bad room config refuses to start" do
    Process.flag(:trap_exit, true)

    assert {:error, "room \"Bad\": unknown profile \"nope\""} =
             Server.start_link(
               adapter: Loopback,
               identity: @alice,
               rooms: [%{"name" => "Bad", "profile" => "nope"}]
             )
  end
end
