defmodule Jido.Console.Terminal.FrameTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Terminal.Frame

  test "normalizes row count and display width" do
    frame = Frame.new(4, 2, ["😀x", "abcdef", "ignored"])

    assert frame.rows == ["😀x ", "abcd"]
    assert Enum.all?(frame.rows, &(Frame.width(&1) == 4))
  end

  test "wraps Unicode text by display width" do
    assert Frame.wrap("a😀b", 3) == ["a😀", "b"]
    assert Frame.width("\e[31m界\e[0m") == 2
  end

  test "removes terminal sequences and controls before rendering" do
    frame = Frame.new(16, 2, ["\e]0;title\a\e[31mred\e[0m", "next\e[2Jline\x00"])

    assert frame.rows == ["red             ", "nextline        "]
  end

  test "handles zero-width fits and empty wrapped lines" do
    assert Frame.fit("text", 0) == ""
    assert Frame.wrap("", 4) == [""]
    assert Frame.wrap("one\n", 4) == ["one", ""]
  end

  test "hides a missing cursor and clamps an invalid cursor" do
    hidden = Frame.new(3, 1, ["a"])
    assert hidden.cursor == nil

    clamped = Frame.new(3, 2, [], cursor: {0, 20})
    assert clamped.cursor == {1, 2}
  end
end
