defmodule Jido.Cli.Tui.SafeTextTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.SafeText

  test "removes terminal control sequences from text and summaries" do
    unsafe = "\e]0;secret title\a\e[31mred\e[0m\nnext\x00\x7F"

    assert SafeText.clean(unsafe) == "red\nnext"
    assert SafeText.summary(unsafe) == "red next"
    refute SafeText.summary(unsafe) =~ "\e"
  end

  test "bounds inspected summaries" do
    assert SafeText.summary(%{value: String.duplicate("x", 500)}, limit: 20) |> String.length() == 20
  end
end
