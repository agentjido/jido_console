defmodule Jido.Console.Release.DecisionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Decision

  test "records a complete v0.1 decision without publishing" do
    assert {:ok, decision} = Decision.record()
    assert decision["version"] == Jido.Console.Release.Identity.version()
    assert decision["decision"] == "pass"
    assert decision["durable_session_recovery"] == false
    assert length(decision["epics"]) == 28
    assert Enum.all?(decision["epics"], &(&1["result"] == "pass"))
    assert decision["channels"] == %{"archive" => "pass", "homebrew" => "pass", "npm" => "pass"}
    assert map_size(decision["gates"]) == 12
    refute inspect(decision) =~ "sk-"
  end

  test "refuses a decision when an earlier epic is missing" do
    reviews = Decision.epics() |> Enum.drop(1) |> Map.new(&{&1, %{"result" => "pass", "proof" => "x"}})
    assert {:error, {:incomplete_evidence, ["jido_console-m1e01"]}} = Decision.record(reviews: reviews)
  end

  test "fails the decision when a reviewed epic did not pass" do
    reviews =
      Map.new(Decision.epics(), fn
        "jido_console-m1e01" -> {"jido_console-m1e01", %{"result" => "fail", "proof" => "x"}}
        id -> {id, %{"result" => "pass", "proof" => "x"}}
      end)

    assert {:ok, decision} = Decision.record(reviews: reviews)
    assert decision["decision"] == "fail"
    assert decision["channels"]["archive"] == "fail"
  end
end
