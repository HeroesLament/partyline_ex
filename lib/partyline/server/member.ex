defmodule Partyline.Server.Member do
  @moduledoc false
  # Per-link member state held by Partyline.Server, mirroring the
  # reference server.Member, including its three token buckets.

  alias Partyline.Protocol.User

  @text_rate 4.0
  @control_rate 6.0
  @max_batch 64

  defstruct [
    :id,
    :link,
    :identity,
    :name,
    :room,
    :hops,
    :rtt_ms,
    :pending_hello,
    mdu: 431,
    link_rtt: 0.0,
    muted: false,
    deaf: false,
    server_muted: false,
    operator: false,
    text_only: false,
    speaker: true,
    admitted: false,
    hello_started: false,
    talking: false,
    joined_at: 0,
    rejected_frames: 0,
    limited_frames: 0,
    frames: {0.0, 0.0, 0.0, 0.0},
    text: {@text_rate, 0.0},
    control: {@control_rate, 0.0}
  ]

  def now, do: System.monotonic_time(:millisecond) / 1_000

  def new(id, link, info) do
    t = now()

    %__MODULE__{
      id: id,
      link: link,
      name: "guest-#{id}",
      mdu: info[:mdu] || 431,
      link_rtt: info[:rtt] || 0.0,
      joined_at: t,
      text: {@text_rate, t},
      control: {@control_rate, t}
    }
  end

  @doc "Reference capped_rtt: link RTT in seconds, at most 5."
  def capped_rtt(%__MODULE__{link_rtt: rtt}), do: min(5.0, rtt || 0.0)

  @doc "Frame bucket for a room: rate 2 x frames/s, capacity max(2 x rate, 64)."
  def reset_frames(member, nil), do: %{member | frames: {0.0, 0.0, 0.0, now()}, talking: false}

  def reset_frames(member, frame_ms) do
    rate = 2 * 1_000 / frame_ms
    capacity = max(2 * rate, @max_batch)
    %{member | frames: {rate, capacity, capacity, now()}, talking: false}
  end

  def allow_frames(%__MODULE__{frames: {rate, capacity, tokens, last}} = member, count) do
    t = now()
    tokens = min(capacity, tokens + (t - last) * rate)

    if tokens >= count,
      do: {true, %{member | frames: {rate, capacity, tokens - count, t}}},
      else: {false, %{member | frames: {rate, capacity, tokens, t}}}
  end

  def allow_text(member), do: bucket(member, :text, @text_rate)
  def allow_control(member), do: bucket(member, :control, @control_rate)

  defp bucket(member, key, rate) do
    {tokens, last} = Map.fetch!(member, key)
    t = now()
    tokens = min(rate, tokens + (t - last) * rate)

    if tokens >= 1,
      do: {true, Map.put(member, key, {tokens - 1, t})},
      else: {false, Map.put(member, key, {tokens, t})}
  end

  def to_user(%__MODULE__{} = m) do
    %User{
      id: m.id,
      name: m.name,
      identity: m.identity && Base.encode16(m.identity, case: :lower),
      room: m.room,
      muted: m.muted,
      deaf: m.deaf,
      hops: m.hops,
      rtt: m.rtt_ms,
      operator: m.operator,
      server_muted: m.server_muted,
      text_only: m.text_only,
      speaker: m.speaker
    }
  end

  def label(%__MODULE__{identity: nil} = m), do: "#{m.name} ##{m.id} (anonymous)"

  def label(%__MODULE__{} = m),
    do: "#{m.name} ##{m.id} <#{Base.encode16(m.identity, case: :lower)}>"
end
