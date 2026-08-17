defmodule Jido.Console.Session.ParityBoundaryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.TestSupport.ClientParityBoundary, as: Boundary

  @production_paths [
    "lib/jido_console/cli/tui.ex",
    "lib/jido_console/session/client/tui.ex",
    "lib/jido_console/session/client/automation.ex",
    "lib/jido_console/session/client/text.ex",
    "lib/jido_console/session/client/json.ex"
  ]

  @proof_paths [
    "test/support/current_client_parity.ex",
    "test/jido_console/session/parity_test.exs"
  ]

  test "production client entries have no raw Jidoka or server bypass" do
    violations =
      for path <- @production_paths,
          token <- Boundary.raw_violations(File.read!(path)),
          do: {path, token}

    assert violations == []
  end

  test "the parity oracle uses live output and not snapshot observation helpers" do
    violations =
      for path <- @proof_paths,
          token <- Boundary.oracle_violations(File.read!(path)),
          do: {path, token}

    assert violations == []
  end

  test "the guard rejects a deliberate raw-path fixture" do
    source = "receive do {:jidoka, event} -> Session.Server.snapshot(event) end"

    assert Boundary.raw_violations(source) == ["{:jidoka,", "Session.Server"]
  end
end
