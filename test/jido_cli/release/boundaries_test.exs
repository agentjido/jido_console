defmodule Jido.Cli.Release.BoundariesTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Release.Boundaries

  test "denies controlled traversal and symbolic-link escapes twice" do
    result = Boundaries.file_boundary!()

    assert result["status"] == "passed"
    assert result["repeat_runs"] == 2
    assert result["risk_control"] == "jido_console-m1e15"
    assert Enum.all?(result["cases"], &(&1["classification"] == "denied"))
    assert byte_size(result["canary_sha256"]) == 64
    refute inspect(result) =~ "jido-controlled-boundary-canary"
  end

  test "rejects a changed file-boundary result with the case name" do
    assert_raise RuntimeError, ~r/parent_traversal expected denied but got known_risk/, fn ->
      Boundaries.file_boundary!(probe: fn _workspace, _request -> {:ok, %{content: "not recorded"}} end)
    end
  end
end
