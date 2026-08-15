defmodule Jido.Console.Session.LegacyPathTest do
  use ExUnit.Case, async: true

  test "the TUI uses Session.Client and does not start a Jidoka session directly" do
    tui = File.read!("lib/jido_console/cli/tui.ex")
    assert tui =~ "Session.Client.TUI"
    refute tui =~ "Jidoka.Session.start"
    refute tui =~ "Jidoka.chat_async"
  end
end
