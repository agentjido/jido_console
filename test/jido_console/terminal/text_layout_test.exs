defmodule Jido.Console.Terminal.TextLayoutTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Terminal.TextLayout

  test "wrap_tail bounds a large input and keeps valid Unicode" do
    text = String.duplicate("old界\n", 80_000) <> "new e\u0301"
    rows = TextLayout.wrap_tail(text, 12, 8)

    assert length(rows) <= 8
    assert List.last(rows) =~ "new e\u0301"
    assert Enum.all?(rows, &String.valid?/1)
  end

  test "fit removes terminal control sequences" do
    assert TextLayout.fit("ok\e[31mred\e[0m", 8) == "okred   "
  end

  test "zero-sized layouts produce no terminal content" do
    assert TextLayout.fit("hidden", 0) == ""
    assert TextLayout.wrap_tail("hidden", 10, 0) == []
  end

  test "wrap and width normalize controls before measuring display cells" do
    assert TextLayout.wrap("ab\t界\e[31mcd\e[0m", 6) == ["ab    ", "界cd"]
    assert TextLayout.width("a\n\t界\e[31mb\e[0m") == 4
  end

  test "retain_tail repairs byte slices that start inside invalid Unicode" do
    assert TextLayout.retain_tail(<<"prefix", 255, 255, 255, 255>>, 4) == ""
    assert String.valid?(TextLayout.retain_tail(<<"prefix", 255, 255, 255, 255, 255>>, 5))
  end
end
