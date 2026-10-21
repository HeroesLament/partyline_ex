defmodule Partyline.ProtocolTest do
  use ExUnit.Case, async: true

  alias Partyline.Protocol
  alias Partyline.Protocol.{Assignment, Channel, Hello, User, Welcome}

  # Byte strings below are what umsgpack (vendored in RNS) emits for the
  # reference's packets, derived from the msgpack spec: small ints are
  # fixints, bytes are bin8 (0xC4), short str are fixstr, None is 0xC0.

  describe "golden bytes" do
    test "TALK_END from a client" do
      assert Protocol.encode_to_server(:talk_end) == <<0x81, 0x13, 0xC3>>
      assert {:ok, [:talk_end]} = Protocol.decode_from_client(<<0x81, 0x13, 0xC3>>)
    end

    test "one Codec2 frame with a sequence number" do
      # {FIELD_FRAMES: b'\x01\x08', FIELD_SEQ: 1}
      wire = <<0x82, 0x01, 0xC4, 0x02, 0x01, 0x08, 0x10, 0x01>>
      assert Protocol.encode_to_server({:frames, [<<1, 8>>], 1}) == wire
      assert {:ok, [{:frames, [<<1, 8>>], 1}]} = Protocol.decode_from_client(wire)
    end

    test "a str where a frame belongs is rejected" do
      wire = <<0x81, 0x01, 0xA2, 0x01, 0x08>>
      assert {:ok, [{:malformed, 0x01, "\x01\x08"}]} = Protocol.decode_from_client(wire)
    end

    test "relayed frame: FRAMES, SPEAKER, SEQ in reference order" do
      # {FIELD_FRAMES: b'\x01\x08', FIELD_SPEAKER: 4, FIELD_SEQ: 300}
      wire = <<0x83, 0x01, 0xC4, 0x02, 0x01, 0x08, 0x02, 0x04, 0x10, 0xCD, 0x01, 0x2C>>
      assert Protocol.encode_to_client({:frames, 4, [<<1, 8>>], 300}) == wire
    end

    test "HELLO keys in reference order" do
      wire = Protocol.encode_to_server({:hello, %Hello{name: "Bob", ver: 1}})
      # map header, FIELD_HELLO, inner map of 11, first key "name"
      assert <<0x81, 0x05, 0x8B, 0xA4, "name", 0xA3, "Bob", 0xA4, "room", 0xC0, _::binary>> = wire
    end

    test "no-room assignment" do
      wire = <<0x81, 0x03, 0x94, 0xC0, 0xC0, 0xC0, 0xC3>>
      assert Protocol.encode_to_client({:room, :none}) == wire
      assert {:ok, [{:room, :none}]} = Protocol.decode_from_server(wire)
    end

    test "join sync channel batch" do
      # {7: [[1, "Lobby", "opus-high", 20, 0, "Open", None, 0, 0]]}
      wire =
        <<0x81, 0x07, 0x91, 0x99, 0x01, 0xA5, "Lobby", 0xA9, "opus-high", 0x14, 0x00, 0xA4, "Open",
          0xC0, 0x00, 0x00>>

      channel = %Channel{
        id: 1,
        name: "Lobby",
        profile: "opus-high",
        frame_ms: 20,
        description: "Open"
      }

      assert Protocol.encode_to_client({:channels, [channel]}) == wire
      assert {:ok, [{:channels, [^channel]}]} = Protocol.decode_from_server(wire)
    end
  end

  describe "client to server" do
    test "HELLO round trip and normalization" do
      hello = %Hello{
        name: "Bob",
        room: "Lobby",
        muted: true,
        hops: 3,
        rtt: 120,
        ver: 1,
        app: "1.0.5"
      }

      assert {:ok, [{:hello, ^hello}]} =
               Protocol.decode_from_client(Protocol.encode_to_server({:hello, hello}))

      wire = Msgpax.pack!(%{5 => %{"hops" => 300, "rtt" => 12.7, "deaf" => 1}}, iodata: false)

      assert {:ok, [{:hello, %Hello{hops: nil, rtt: 12, deaf: true}}]} =
               Protocol.decode_from_client(wire)
    end

    test "a HELLO that isn't a map is malformed" do
      wire = Msgpax.pack!(%{5 => [1, 2]}, iodata: false)
      assert {:ok, [{:malformed, 5, [1, 2]}]} = Protocol.decode_from_client(wire)
    end

    test "control messages" do
      messages = [
        {:move, 2, "hunter2"},
        {:text, "hi all"},
        {:state, true, false},
        {:poke, 4, "wake up"},
        {:admin, "kick", 4, nil},
        {:dialin, "answer", "0123abcd"},
        {:config, "motd", "new motd"}
      ]

      for message <- messages do
        assert {:ok, [^message]} = Protocol.decode_from_client(Protocol.encode_to_server(message))
      end
    end

    test "frame batches: bare single, array of many, at most 64" do
      frames = for i <- 1..3, do: <<2, 0, i, i, i, i>>

      assert {:ok, [{:frames, ^frames, 9}]} =
               Protocol.decode_from_client(Protocol.encode_to_server({:frames, frames, 9}))

      too_many = Msgpax.pack!(%{1 => List.duplicate(Msgpax.Bin.new(<<2, 0>>), 65)}, iodata: false)
      assert {:ok, [{:malformed, 1, _}]} = Protocol.decode_from_client(too_many)

      mixed = Msgpax.pack!(%{1 => [Msgpax.Bin.new(<<2, 0>>), "str"]}, iodata: false)
      assert {:ok, [{:malformed, 1, _}]} = Protocol.decode_from_client(mixed)
    end

    test "sequence numbers wrap at 16 bits and bad ones are dropped" do
      assert Protocol.encode_to_server({:frames, [<<1, 8>>], 0x1_0002}) ==
               Protocol.encode_to_server({:frames, [<<1, 8>>], 2})

      wire = Msgpax.pack!(%{1 => Msgpax.Bin.new(<<1, 8>>), 0x10 => -1}, iodata: false)
      assert {:ok, [{:frames, [<<1, 8>>], nil}]} = Protocol.decode_from_client(wire)
    end

    test "fields decode in reference handler order" do
      wire =
        Msgpax.pack!(
          %{0x13 => true, 0x0C => "t", 0x0A => [1, nil], 0x01 => Msgpax.Bin.new(<<1, 8>>)},
          iodata: false
        )

      assert {:ok, [{:frames, _, nil}, {:move, 1, nil}, {:text, "t"}, :talk_end]} =
               Protocol.decode_from_client(wire)
    end
  end

  describe "server to client" do
    test "WELCOME" do
      welcome = %Welcome{name: "Srv", sid: 7, motd: "hello", ver: 1, app: "1.0.5"}

      assert {:ok, [{:welcome, ^welcome}]} =
               Protocol.decode_from_server(Protocol.encode_to_client({:welcome, welcome}))

      wire = Msgpax.pack!(%{6 => %{"sid" => 7}}, iodata: false)

      assert {:ok, [{:welcome, %Welcome{name: "server", motd: "", app: "unknown"}}]} =
               Protocol.decode_from_server(wire)

      wire = Msgpax.pack!(%{6 => %{"name" => "x"}}, iodata: false)
      assert {:ok, [{:malformed, 6, _}]} = Protocol.decode_from_server(wire)
    end

    test "a single USER record and short records get reference defaults" do
      wire = Msgpax.pack!(%{8 => [3, "bob", nil, 1, false, false]}, iodata: false)

      assert {:ok, [{:users, [user]}]} = Protocol.decode_from_server(wire)
      assert %User{id: 3, name: "bob", room: 1, speaker: true, operator: false, rtt: nil} = user
    end

    test "USER round trip, single and batch" do
      user = %User{
        id: 3,
        name: "bob",
        identity: String.duplicate("ab", 16),
        room: 1,
        muted: true,
        hops: 2,
        rtt: 340,
        operator: true,
        speaker: false
      }

      assert {:ok, [{:users, [^user]}]} =
               Protocol.decode_from_server(Protocol.encode_to_client({:user, user}))

      assert {:ok, [{:users, [^user, ^user]}]} =
               Protocol.decode_from_server(Protocol.encode_to_client({:users, [user, user]}))
    end

    test "bad records are reported individually" do
      wire =
        Msgpax.pack!(
          %{7 => [[1, "A", "opus-high", 20, 0, ""], [2, "B", "no-such", 20, 0, ""]]},
          iodata: false
        )

      assert {:ok, [{:channels, [%Channel{id: 1}]}, {:malformed, 7, [2 | _]}]} =
               Protocol.decode_from_server(wire)
    end

    test "fallback names and sanitized text" do
      wire =
        Msgpax.pack!(
          %{
            7 => [[5, "", "c2-700", 400, 1, "x\ty"]],
            0x0C => [3, "  hi\0 there "],
            0x12 => "notice\u200B"
          },
          iodata: false
        )

      assert {:ok,
              [
                {:channels, [%Channel{name: "Room 5", description: "xy"}]},
                {:notice, "notice"},
                {:text, 3, "hi there"}
              ]} = Protocol.decode_from_server(wire)
    end

    test "room assignment" do
      a = %Assignment{room_id: 2, profile: "c2-1200", frame_ms: 400, can_speak: false}

      assert {:ok, [{:room, ^a}]} =
               Protocol.decode_from_server(Protocol.encode_to_client({:room, a}))

      wire = Msgpax.pack!(%{3 => [2, "nope", 20, true]}, iodata: false)
      assert {:ok, [{:malformed, 3, _}]} = Protocol.decode_from_server(wire)
    end

    test "denied, poke, dialin, config, channel_gone, talk_end, user_left, synced" do
      messages = [
        {:user_left, 9},
        :synced,
        {:denied, nil, "wrong server password"},
        {:poke, 2, "hey"},
        {:dialin, "waiting", String.duplicate("0f", 16)},
        {:config, ["room", 3, %{"name" => "R"}]},
        {:channel_gone, 3},
        {:talk_end, 4}
      ]

      wire = Protocol.encode_to_client(messages)
      assert {:ok, decoded} = Protocol.decode_from_server(wire)
      assert decoded == messages
    end

    test "relayed frames keep placeholders for non-bin elements" do
      wire =
        Msgpax.pack!(
          %{1 => [Msgpax.Bin.new(<<1, 8>>), "oops", Msgpax.Bin.new(<<1, 9>>)], 2 => 4, 0x10 => 100},
          iodata: false
        )

      assert {:ok, [{:frames, 4, [<<1, 8>>, nil, <<1, 9>>], 100}]} =
               Protocol.decode_from_server(wire)
    end

    test "relayed frames round trip; speaker defaults to 0" do
      assert {:ok, [{:frames, 4, [<<1, 8>>], 65_535}]} =
               Protocol.decode_from_server(
                 Protocol.encode_to_client({:frames, 4, [<<1, 8>>], 65_535})
               )

      wire = Msgpax.pack!(%{1 => Msgpax.Bin.new(<<1, 8>>)}, iodata: false)
      assert {:ok, [{:frames, 0, [<<1, 8>>], nil}]} = Protocol.decode_from_server(wire)
    end
  end

  test "non-map and invalid packets" do
    assert {:error, {:not_a_map, [1]}} = Protocol.decode_from_client(<<0x91, 0x01>>)
    assert {:error, {:msgpack, _}} = Protocol.decode_from_server(<<0xC1>>)
  end

  test "the same field twice in one packet is a programming error" do
    assert_raise ArgumentError, fn ->
      Protocol.encode_to_client([{:notice, "a"}, {:notice, "b"}])
    end
  end

  test "record_batch rule" do
    assert Protocol.record_batch([[1], [2]]) == [[1], [2]]
    assert Protocol.record_batch([1, 2]) == [[1, 2]]
    assert Protocol.record_batch([]) == [[]]
  end
end
