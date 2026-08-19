defmodule Jido.Console.Session.ParityBoundaryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.TestSupport.ClientParityBoundary, as: Boundary

  @production_paths [
    "lib/jido_console/cli/tui.ex",
    "lib/jido_console/session/client/tui.ex"
  ]

  test "production client entries have no raw Jidoka or server bypass" do
    violations =
      for path <- @production_paths,
          token <- Boundary.raw_violations(File.read!(path)),
          do: {path, token}

    assert violations == []
  end

  test "the guard rejects a deliberate raw-path fixture" do
    source = "receive do {:jidoka, event} -> Session.Server.snapshot(event) end"

    assert Boundary.raw_violations(source) == ["{:jidoka,", "Session.Server"]
  end
end
