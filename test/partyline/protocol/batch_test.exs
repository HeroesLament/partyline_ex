defmodule Partyline.Protocol.BatchTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [&&&: 2]

  alias Partyline.Protocol
  alias Partyline.Protocol.{Batch, Channel}

  test "client flush rule" do
    frame = :binary.copy(<<0>>, 100)
    # 8 + packed + 103 > 431 - 16
    refute Batch.client_flush_before?(0, 1_000, frame, 431)
    refute Batch.client_flush_before?(3, 304, frame, 431)
    assert Batch.client_flush_before?(3, 305, frame, 431)
  end

  test "client target count" do
    assert Batch.client_target_count(20) == 1
    assert Batch.client_target_count(20, 4) == 4
    assert Batch.client_target_count(20, 999) == 64
    assert Batch.client_target_count(400, 1, true) == 6
    assert Batch.client_target_count(20, 1, true) == 64
  end

  test "relay chunks fit the MDU and carry sequence offsets" do
    frames = for i <- 0..9, do: :binary.copy(<<i>>, 62)
    chunks = Batch.relay_chunks(frames, 200)

    assert Enum.map(chunks, &elem(&1, 1)) == [0, 2, 4, 6, 8]
    assert Enum.flat_map(chunks, &elem(&1, 0)) == frames

    for {chunk, offset} <- chunks do
      packet =
        Protocol.encode_to_client({:frames, 7, chunk, 65_534 + offset &&& 0xFFFF})

      assert byte_size(packet) <= 200
    end
  end

  test "relay chunks with nothing to split" do
    assert Batch.relay_chunks([<<1, 2>>], 431) == [{[<<1, 2>>], 0}]
    assert Batch.relay_chunks([], 431) == []
  end

  test "join sync record batches stay within the MDU" do
    channels =
      for id <- 1..40 do
        Channel.to_wire(%Channel{
          id: id,
          name: "Room number #{id}",
          profile: "opus-high",
          frame_ms: 20,
          description: "a description that takes some room"
        })
      end

    batches = Batch.record_batches(channels, 431)
    assert length(batches) > 1
    assert Enum.concat(batches) == channels

    for batch <- batches do
      assert byte_size(Msgpax.pack!(%{7 => batch}, iodata: false)) <= 431
    end
  end
end
