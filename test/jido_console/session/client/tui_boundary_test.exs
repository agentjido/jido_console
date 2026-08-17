defmodule Jido.Console.Session.Client.TuiBoundaryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client.Boundary

  @tui_paths ["lib/jido_console/cli/tui.ex"] ++
               Path.wildcard("lib/jido_console/cli/tui/*.ex") ++
               ["lib/jido_console/session/client/tui.ex"]

  @legacy_owner_paths [
    "lib/jido_console/session/server.ex",
    "lib/jido_console/session/delivery.ex",
    "lib/jido_console/session/recovery.ex",
    "lib/jido_console/session/client/local.ex"
  ]

  @production_paths Path.wildcard("lib/**/*.ex")
  @violation_fixture "test/fixtures/session/legacy_tui_client_path.fixture"

  test "the production TUI has no raw owner or runtime path" do
    assert :ok = Boundary.check(@tui_paths)
  end

  test "the session owner has no deleted compatibility path" do
    assert Boundary.legacy_path_violations(@legacy_owner_paths) == []
  end

  test "only the session owner receives raw Jidoka events" do
    ingresses =
      @production_paths
      |> Boundary.jidoka_ingresses()
      |> Enum.map(&Map.take(&1, [:path, :function]))

    assert ingresses == [
             %{
               path: "lib/jido_console/session/server.ex",
               function: {:handle_info, 2}
             }
           ]
  end

  test "the syntax guard rejects a deliberate old path" do
    violations = Boundary.violations([@violation_fixture])
    legacy = Boundary.legacy_path_violations([@violation_fixture])

    assert {:error, {:client_boundary_bypass, _violation}} = Boundary.check([@violation_fixture])
    assert Enum.any?(violations, &(&1.kind == :forbidden_module))
    assert Enum.any?(violations, &(&1.kind == :raw_message))
    assert Enum.any?(legacy, &(&1.kind == :legacy_option))
    assert Enum.any?(legacy, &(&1.kind == :legacy_function))
    assert Enum.any?(legacy, &(&1.kind == :legacy_facade))
  end
end
