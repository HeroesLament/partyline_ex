defmodule Partyline.Transport.RNSTest do
  use ExUnit.Case, async: true

  alias Partyline.Transport.RNS, as: Adapter

  test "lxst.room name hash matches the reference derivation" do
    # Python: RNS.Identity.full_hash("lxst.room".encode())[:NAME_HASH_LENGTH//8]
    expected = binary_part(:crypto.hash(:sha256, "lxst.room"), 0, 10)
    assert Adapter.name_hash() == expected
  end

  test "destination name is lxst.room" do
    assert Adapter.destination_name() == {"lxst", ["room"]}
  end

  test "identity resolution" do
    assert {:ok, nil} = Adapter.resolve_identity(nil)
    assert {:error, {:bad_identity, :nope}} = Adapter.resolve_identity(:nope)
  end
end
