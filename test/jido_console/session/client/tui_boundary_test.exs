defmodule Jido.Console.Session.Client.TUIBoundaryTest do
  use ExUnit.Case, async: true

  test "the TUI consumes Session.View and no raw Jidoka event" do
    root = Path.expand("../../../..", __DIR__)
    tui = File.read!(Path.join(root, "lib/jido_console/cli/tui/app.ex"))
    adapter = File.read!(Path.join(root, "lib/jido_console/session/client/tui.ex"))

    assert tui =~ "jido_console_view"
    assert adapter =~ "Session.View"
    refute tui =~ "jidoka_turn_event"
    refute adapter =~ "Jidoka.Event"
    refute adapter =~ "apply_event"
  end
end
