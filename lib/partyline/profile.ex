defmodule Partyline.Profile do
  @moduledoc """
  Room codec profiles and audio frame validation.

  A wire frame is `codec_byte <> codec_payload`, with codec bytes taken
  from LXST (`OPUS = 0x01`, `CODEC2 = 0x02`):

    * Opus: one raw Opus packet covering the whole room frame duration.
    * Codec2: `mode_header <> n concatenated codec2 frames` at 8 kHz.

  Servers validate every frame against the room profile: binary, length
  between 2 and the profile limit, matching codec byte, and decoded
  duration exactly equal to the profile's frame length. The duration is
  read from the Opus TOC byte or computed from the Codec2 body length,
  so validation needs no codec.

  Parameters mirror partyline 1.0.5 `common.PROFILES` and LXST 0.5.4
  `Codecs.Opus` / `Codecs.Codec2`.
  """

  import Bitwise

  @opus_byte 0x01
  @codec2_byte 0x02
  @max_frame_bytes 400

  @enforce_keys [:name, :codec, :frame_ms, :description, :params]
  defstruct [:name, :codec, :frame_ms, :description, :params, :max_frame_bytes]

  @type codec :: :opus | :codec2
  @type t :: %__MODULE__{
          name: String.t(),
          codec: codec(),
          frame_ms: pos_integer(),
          description: String.t(),
          params: map(),
          max_frame_bytes: pos_integer()
        }

  # LXST Opus profile parameters, keyed by profile constant.
  @opus %{
    voice_low: %{
      lxst_profile: 0x00,
      samplerate: 8_000,
      channels: 1,
      application: :voip,
      bitrate_ceiling: 6_000
    },
    voice_medium: %{
      lxst_profile: 0x01,
      samplerate: 24_000,
      channels: 1,
      application: :voip,
      bitrate_ceiling: 8_000
    },
    voice_high: %{
      lxst_profile: 0x02,
      samplerate: 48_000,
      channels: 1,
      application: :voip,
      bitrate_ceiling: 16_000
    },
    audio_low: %{
      lxst_profile: 0x05,
      samplerate: 12_000,
      channels: 1,
      application: :audio,
      bitrate_ceiling: 14_000
    },
    audio_medium: %{
      lxst_profile: 0x06,
      samplerate: 24_000,
      channels: 2,
      application: :audio,
      bitrate_ceiling: 28_000
    },
    audio_high: %{
      lxst_profile: 0x07,
      samplerate: 48_000,
      channels: 2,
      application: :audio,
      bitrate_ceiling: 56_000
    }
  }

  # Codec2 modes: LXST mode header, bytes per codec2 frame, ms per codec2
  # frame (samples_per_frame / 8 kHz). Bytes are ceil(bits/8).
  @codec2_modes %{
    700 => %{mode_header: 0x00, bytes_per_frame: 4, ms_per_frame: 40},
    1200 => %{mode_header: 0x01, bytes_per_frame: 6, ms_per_frame: 40},
    1300 => %{mode_header: 0x02, bytes_per_frame: 7, ms_per_frame: 40},
    1400 => %{mode_header: 0x03, bytes_per_frame: 7, ms_per_frame: 40},
    1600 => %{mode_header: 0x04, bytes_per_frame: 8, ms_per_frame: 40},
    2400 => %{mode_header: 0x05, bytes_per_frame: 6, ms_per_frame: 20},
    3200 => %{mode_header: 0x06, bytes_per_frame: 8, ms_per_frame: 20}
  }

  @codec2_by_header Map.new(@codec2_modes, fn {mode, p} ->
                      {p.mode_header, Map.put(p, :mode, mode)}
                    end)

  # name => {codec, codec argument, frame ms, description}
  @table [
    {"opus-high", :opus, :voice_high, 20, "Opus 16 kbps, 20 ms frames"},
    {"opus-med", :opus, :voice_medium, 60, "Opus 8 kbps, 60 ms frames"},
    {"opus-low", :opus, :voice_low, 60, "Opus 6 kbps, 60 ms frames"},
    {"c2-3200", :codec2, 3200, 200, "Codec2 3200 bps, 200 ms frames"},
    {"c2-2400", :codec2, 2400, 200, "Codec2 2400 bps, 200 ms frames"},
    {"c2-1200", :codec2, 1200, 400, "Codec2 1200 bps, 400 ms frames"},
    {"c2-700", :codec2, 700, 400, "Codec2 700 bps, 400 ms frames"},
    {"music-low", :opus, :audio_low, 40, "Opus music 14 kbps, 40 ms frames"},
    {"music-med", :opus, :audio_medium, 40, "Opus music 28 kbps, 40 ms frames"},
    {"music-high", :opus, :audio_high, 40, "Opus music 56 kbps, 40 ms frames"}
  ]

  @profiles (for {name, codec, arg, ms, desc} <- @table, into: %{} do
               params =
                 case codec do
                   :opus -> Map.put(Map.fetch!(@opus, arg), :profile, arg)
                   :codec2 -> Map.put(Map.fetch!(@codec2_modes, arg), :mode, arg)
                 end

               limit =
                 case codec do
                   :opus ->
                     # 1 + ceil(ceiling/8 * ms/1000), capped at MAX_FRAME_BYTES
                     min(@max_frame_bytes, 1 + div(params.bitrate_ceiling * ms + 7_999, 8_000))

                   :codec2 ->
                     @max_frame_bytes
                 end

               # Plain map here; the struct can't be built inside its own
               # module body. fetch/1 converts.
               {name,
                %{
                  name: name,
                  codec: codec,
                  frame_ms: ms,
                  description: desc,
                  params: params,
                  max_frame_bytes: limit
                }}
             end)

  @names Enum.map(@table, &elem(&1, 0))

  @doc "Every profile name, in reference order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Look up a profile by name."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(name) when is_binary(name) do
    case Map.fetch(@profiles, name) do
      {:ok, fields} -> {:ok, struct!(__MODULE__, fields)}
      :error -> :error
    end
  end

  def fetch(_), do: :error

  @spec fetch!(String.t()) :: t()
  def fetch!(name), do: struct!(__MODULE__, Map.fetch!(@profiles, name))

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Map.has_key?(@profiles, name)

  @doc "Codec header byte for a profile or codec."
  @spec codec_byte(t() | codec()) :: byte()
  def codec_byte(%__MODULE__{codec: codec}), do: codec_byte(codec)
  def codec_byte(:opus), do: @opus_byte
  def codec_byte(:codec2), do: @codec2_byte

  @doc "Codec named by a frame's first byte, or nil."
  @spec codec_of(binary()) :: codec() | nil
  def codec_of(<<@opus_byte, _::binary>>), do: :opus
  def codec_of(<<@codec2_byte, _::binary>>), do: :codec2
  def codec_of(_), do: nil

  @doc """
  Duration in ms of a wire frame (codec byte included), or nil if it
  can't be determined. Opus 2.5 ms frames give float results.
  """
  @spec frame_duration_ms(binary()) :: number() | nil
  def frame_duration_ms(<<@opus_byte, packet::binary>>), do: opus_duration_ms(packet)
  def frame_duration_ms(<<@codec2_byte, payload::binary>>), do: codec2_duration_ms(payload)
  def frame_duration_ms(_), do: nil

  @doc "Duration of a raw Opus packet from its TOC byte (RFC 6716 section 3.1)."
  @spec opus_duration_ms(binary()) :: number() | nil
  def opus_duration_ms(<<toc, rest::binary>>) do
    config = toc >>> 3
    code = toc &&& 3

    size =
      cond do
        config < 12 -> elem({10, 20, 40, 60}, rem(config, 4))
        config < 16 -> elem({10, 20}, rem(config, 2))
        true -> elem({2.5, 5, 10, 20}, rem(config, 4))
      end

    count =
      case {code, rest} do
        {0, _} -> 1
        {c, _} when c < 3 -> 2
        {3, <<frame_count, _::binary>>} -> frame_count &&& 0x3F
        {3, <<>>} -> nil
      end

    count && size * count
  end

  def opus_duration_ms(_), do: nil

  @doc "Duration of a Codec2 payload (`mode_header <> frames`)."
  @spec codec2_duration_ms(binary()) :: number() | nil
  def codec2_duration_ms(<<header, body::binary>>) when byte_size(body) >= 1 do
    case Map.fetch(@codec2_by_header, header) do
      {:ok, %{bytes_per_frame: bpf, ms_per_frame: ms}} ->
        if rem(byte_size(body), bpf) == 0, do: div(byte_size(body), bpf) * ms, else: nil

      :error ->
        nil
    end
  end

  def codec2_duration_ms(_), do: nil

  @doc "The reference server's per-frame check (`common.valid_frame`)."
  @spec valid_frame?(term(), t() | String.t()) :: boolean()
  def valid_frame?(frame, name) when is_binary(name) do
    case fetch(name) do
      {:ok, profile} -> valid_frame?(frame, profile)
      :error -> false
    end
  end

  def valid_frame?(frame, %__MODULE__{} = profile) when is_binary(frame) do
    size = byte_size(frame)

    size >= 2 and size <= profile.max_frame_bytes and
      :binary.first(frame) == codec_byte(profile) and
      frame_duration_ms(frame) == profile.frame_ms
  end

  def valid_frame?(_frame, _profile), do: false

  @doc "Codec2 mode parameters for a mode header byte."
  @spec codec2_mode_for_header(byte()) :: {:ok, map()} | :error
  def codec2_mode_for_header(header), do: Map.fetch(@codec2_by_header, header)
end
