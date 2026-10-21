defmodule Partyline.Protocol.Batch do
  @moduledoc """
  MDU cost models the reference uses to decide how much fits in one link
  packet. They are estimates of msgpack overhead, not exact sizes, and a
  compatible implementation should make the same decisions so batch
  boundaries (and therefore sequence numbering and latency) match.

    * Client packetizer (`CountingPacketizer._ingest`): a pending batch
      is flushed before adding a frame when
      `8 + packed + (len(frame) + 3) > mdu - 16`.
    * Server relay (`Server.relay_split`): a received batch that encodes
      larger than the recipient's MDU is re-split, starting a new chunk
      when `12 + packed + (len(frame) + 3) > mdu - 8`.
    * Join sync (`Server.send_records`): CHANNEL and USER records are
      packed per packet while `5 + sum(len(packb(record))) <= mdu - 8`.
  """

  @default_mdu 431

  @batch_base_cost 8
  @batch_margin 16
  @relay_base_cost 12
  @relay_margin 8
  @sync_base 5
  @sync_margin 8
  @fill_max_ms 2_500

  def default_mdu, do: @default_mdu

  @doc "Packed-cost estimate of one frame inside a batch."
  @spec frame_cost(binary()) :: pos_integer()
  def frame_cost(frame), do: byte_size(frame) + 3

  @doc """
  Client side: whether `frame` must start a new batch because the
  pending one (`pending_count` frames, `packed` estimated bytes) would
  overflow the MDU.
  """
  @spec client_flush_before?(non_neg_integer(), non_neg_integer(), binary(), pos_integer()) ::
          boolean()
  def client_flush_before?(pending_count, packed, frame, mdu) do
    pending_count > 0 and @batch_base_cost + packed + frame_cost(frame) > mdu - @batch_margin
  end

  @doc """
  Client side: frames per packet. Normal rooms send `frames_per_packet`
  (default 1). With `fill_mtu` (push-to-talk rooms) the target is as many
  frames as fit in 2.5 s, capped at 64; the MDU check above still flushes
  earlier.
  """
  @spec client_target_count(pos_integer(), pos_integer(), boolean()) :: pos_integer()
  def client_target_count(frame_ms, frames_per_packet \\ 1, fill_mtu \\ false)

  def client_target_count(_frame_ms, frames_per_packet, false),
    do: frames_per_packet |> max(1) |> min(Partyline.Protocol.max_batch())

  def client_target_count(frame_ms, _frames_per_packet, true),
    do: div(@fill_max_ms, max(1, frame_ms)) |> max(1) |> min(Partyline.Protocol.max_batch())

  @doc """
  Server side: split a batch for a recipient whose MDU can't carry it.
  Returns `{frames, offset}` chunks; `offset` is the index of the chunk's
  first frame in the original batch, so the chunk's sequence number is
  `(base_seq + offset) &&& 0xFFFF`.
  """
  @spec relay_chunks([binary()], pos_integer()) :: [{[binary()], non_neg_integer()}]
  def relay_chunks(frames, mdu) do
    {chunks, chunk, start, _packed, _index} =
      Enum.reduce(frames, {[], [], 0, 0, 0}, fn frame, {chunks, chunk, start, packed, index} ->
        cost = frame_cost(frame)

        if chunk != [] and @relay_base_cost + packed + cost > mdu - @relay_margin do
          {[{Enum.reverse(chunk), start} | chunks], [frame], index, cost, index + 1}
        else
          {chunks, [frame | chunk], start, packed + cost, index + 1}
        end
      end)

    chunks =
      case chunk do
        [] -> chunks
        _ -> [{Enum.reverse(chunk), start} | chunks]
      end

    Enum.reverse(chunks)
  end

  @doc """
  Server side: group join-sync records into per-packet batches. Cost is
  the packed size of `to_wire.(record)`; pass `&Channel.to_wire/1` or
  `&User.to_wire/1` to batch structs, or nothing for wire-form lists.
  """
  @spec record_batches([term()], pos_integer(), (term() -> term())) :: [[term()]]
  def record_batches(records, mdu, to_wire \\ & &1) do
    limit = mdu - @sync_margin

    {batches, batch, _packed} =
      Enum.reduce(records, {[], [], @sync_base}, fn record, {batches, batch, packed} ->
        cost = record |> to_wire.() |> Msgpax.pack!(iodata: false) |> byte_size()

        if batch != [] and packed + cost > limit do
          {[Enum.reverse(batch) | batches], [record], @sync_base + cost}
        else
          {batches, [record | batch], packed + cost}
        end
      end)

    batches =
      case batch do
        [] -> batches
        _ -> [Enum.reverse(batch) | batches]
      end

    Enum.reverse(batches)
  end
end
