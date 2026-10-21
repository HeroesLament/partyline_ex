defmodule Partyline.Protocol.TextTest do
  use ExUnit.Case, async: true

  alias Partyline.Protocol.Text

  test "strips unprintables and collapses whitespace" do
    assert Text.clean("  a\tb\0c  ", 300) == "abc"
    assert Text.clean("a   b\u3000 c", 300) == "a b c"
    assert Text.clean("x\u200By", 300) == "xy"
  end

  test "empty and non-strings fall back" do
    assert Text.clean("   ", 300, "fb") == "fb"
    assert Text.clean(nil, 300, "fb") == "fb"
    assert Text.clean(42, 300) == ""
    assert Text.clean(%Msgpax.Bin{data: "bytes"}, 300, :nope) == :nope
  end

  test "truncates to a byte limit on a character boundary" do
    assert Text.clean("héllo", 2) == "h"
    assert Text.clean("héllo", 3) == "hé"
    assert byte_size(Text.clean(String.duplicate("€", 40), 48)) == 48
  end

  test "name_key folds case, compatibility forms and format characters" do
    assert Text.name_key("Straße") == Text.name_key("STRASSE")
    assert Text.name_key("ｂｏｂ") == Text.name_key("BOB")
    assert Text.name_key("bo\u200Db") == "bob"
  end

  test "python truthiness" do
    refute Text.truthy?(nil)
    refute Text.truthy?(0)
    refute Text.truthy?("")
    refute Text.truthy?([])
    assert Text.truthy?(1)
    assert Text.truthy?("0")
  end
end
