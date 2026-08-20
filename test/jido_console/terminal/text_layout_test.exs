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
end
