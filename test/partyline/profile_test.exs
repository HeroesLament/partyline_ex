defmodule Partyline.ProfileTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Partyline.Profile

  # Opus TOC byte: config in the top 5 bits, frame-count code in the low 2.
  defp toc(config, code \\ 0), do: config <<< 3 ||| code

  test "profile names in reference order" do
    assert Profile.names() ==
             ~w(opus-high opus-med opus-low c2-3200 c2-2400 c2-1200 c2-700 music-low music-med music-high)
  end

  # common.FRAME_LIMITS computed by the reference with LXST 0.5.4.
  test "frame limits" do
    limits = Map.new(Profile.names(), &{&1, Profile.fetch!(&1).max_frame_bytes})

    assert limits == %{
             "opus-high" => 41,
             "opus-med" => 61,
             "opus-low" => 46,
             "music-low" => 71,
             "music-med" => 141,
             "music-high" => 281,
             "c2-3200" => 400,
             "c2-2400" => 400,
             "c2-1200" => 400,
             "c2-700" => 400
           }
  end

  describe "Opus TOC durations" do
    test "SILK" do
      assert Profile.opus_duration_ms(<<toc(1)>>) == 20
      assert Profile.opus_duration_ms(<<toc(3)>>) == 60
    end

    test "hybrid" do
      assert Profile.opus_duration_ms(<<toc(13)>>) == 20
    end

    test "CELT, multi-frame codes" do
      assert Profile.opus_duration_ms(<<toc(31)>>) == 20
      assert Profile.opus_duration_ms(<<toc(31, 1)>>) == 40
      assert Profile.opus_duration_ms(<<toc(31, 2)>>) == 40
      assert Profile.opus_duration_ms(<<toc(31, 3), 3>>) == 60
      # 8 x 2.5 ms
      assert Profile.opus_duration_ms(<<toc(16, 3), 8>>) == 20
    end

    test "code 3 without a count byte is unknown" do
      assert Profile.opus_duration_ms(<<toc(31, 3)>>) == nil
      assert Profile.opus_duration_ms(<<>>) == nil
    end
  end

  describe "valid_frame?" do
    test "opus-high: 20 ms, at most 41 bytes" do
      assert Profile.valid_frame?(<<1, toc(31)>> <> :binary.copy(<<0>>, 39), "opus-high")
      refute Profile.valid_frame?(<<1, toc(31)>> <> :binary.copy(<<0>>, 40), "opus-high")
      # 60 ms SILK in a 20 ms room
      refute Profile.valid_frame?(<<1, toc(3), 0>>, "opus-high")
      # Codec2 byte in an Opus room
      refute Profile.valid_frame?(<<2, 0x05>> <> :binary.copy(<<0>>, 60), "opus-high")
    end

    test "c2-1200: mode header 0x01, ten 6-byte frames" do
      assert Profile.valid_frame?(<<2, 0x01>> <> :binary.copy(<<0>>, 60), "c2-1200")
      refute Profile.valid_frame?(<<2, 0x01>> <> :binary.copy(<<0>>, 54), "c2-1200")
      refute Profile.valid_frame?(<<2, 0x01>> <> :binary.copy(<<0>>, 61), "c2-1200")
      # 2400 header: same byte count but 200 ms
      refute Profile.valid_frame?(<<2, 0x05>> <> :binary.copy(<<0>>, 60), "c2-1200")
    end

    test "c2-700 and c2-3200" do
      assert Profile.valid_frame?(<<2, 0x00>> <> :binary.copy(<<0>>, 40), "c2-700")
      assert Profile.valid_frame?(<<2, 0x06>> <> :binary.copy(<<0>>, 80), "c2-3200")
    end

    test "non-binaries and short frames" do
      refute Profile.valid_frame?(nil, "c2-700")
      refute Profile.valid_frame?(<<1>>, "opus-high")
      refute Profile.valid_frame?(<<2, 0x00>>, "c2-700")
      refute Profile.valid_frame?(<<2, 0x00, 0, 0, 0, 0>>, "no-such-profile")
    end
  end
end
