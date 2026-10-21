defmodule Partyline.Protocol.AnnounceDataTest do
  use ExUnit.Case, async: true

  alias Partyline.Protocol.AnnounceData

  test "trailing empties trimmed to three fields, matching umsgpack bytes" do
    # umsgpack.packb([1, "srv", 0])
    assert AnnounceData.pack("srv", 0) == <<0x93, 0x01, 0xA3, "srv", 0x00>>
  end

  test "keeps fields up to the last non-empty one" do
    assert {:ok, [1, "srv", 2, "", "en"]} =
             Msgpax.unpack(AnnounceData.pack("srv", 2, language: "en"))
  end

  test "round trip" do
    data = AnnounceData.pack("Lobby server", 2, description: "desc", language: "en", country: "US")
    assert {:ok, info} = AnnounceData.unpack(data)
    assert info.name == "Lobby server"
    assert info.version == 1
    assert AnnounceData.password?(info)
    refute AnnounceData.hidden?(info)
    assert {info.description, info.language, info.country} == {"desc", "en", "US"}
  end

  test "hidden servers announce an empty name" do
    assert {:ok, %{name: nil} = info} = AnnounceData.unpack(AnnounceData.pack("", 1))
    assert AnnounceData.hidden?(info)
  end

  test "rejects what the reference rejects" do
    assert :error = AnnounceData.unpack(<<0xC1>>)
    assert :error = AnnounceData.unpack(Msgpax.pack!(["1", "x"], iodata: false))
    assert :error = AnnounceData.unpack(Msgpax.pack!([1], iodata: false))
  end

  test "a bin-typed name is not a name" do
    data = Msgpax.pack!([1, Msgpax.Bin.new("srv"), 0], iodata: false)
    assert {:ok, %{name: nil}} = AnnounceData.unpack(data)
  end

  test "missing or non-integer flags default to zero" do
    assert {:ok, %{flags: 0}} = AnnounceData.unpack(Msgpax.pack!([1, "s"], iodata: false))
    assert {:ok, %{flags: 0}} = AnnounceData.unpack(Msgpax.pack!([1, "s", "x"], iodata: false))
  end
end
