defmodule Jido.Cli.Terminal.FrameTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Terminal.Frame

  test "normalizes row count and display width" do
    frame = Frame.new(4, 2, ["😀x", "abcdef", "ignored"])

    assert frame.rows == ["😀x ", "abcd"]
    assert Enum.all?(frame.rows, &(Frame.width(&1) == 4))
  end

  test "wraps Unicode text by display width" do
    assert Frame.wrap("a😀b", 3) == ["a😀", "b"]
  end

  test "renders the cursor and complete rows" do
    output = Frame.new(5, 2, ["one"], cursor: {4, 2}) |> Frame.to_iodata() |> IO.iodata_to_binary()

    assert output =~ "\e[H"
    assert output =~ "one  "
    assert output =~ "\e[2;4H\e[?25h"
  end

  test "handles zero-width fits and empty wrapped lines" do
    assert Frame.fit("text", 0) == ""
    assert Frame.wrap("", 4) == [""]
    assert Frame.wrap("one\n", 4) == ["one", ""]
  end

  test "hides a missing cursor and clamps an invalid cursor" do
    hidden = Frame.new(3, 1, ["a"])
    assert hidden |> Frame.to_iodata() |> IO.iodata_to_binary() =~ "\e[?25l"

    clamped = Frame.new(3, 2, [], cursor: {0, 20})
    assert clamped.cursor == {1, 2}
  end
end
