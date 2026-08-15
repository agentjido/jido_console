defmodule Jido.Console.Release.PublishTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Decision, Publish}

  test "holds publication until the protected workflow runs" do
    assert {:ok, plan} = Publish.from_decision()
    assert plan["published"] == false
    assert {:ok, held} = Publish.execute(plan)
    assert held["status"] == "held"
    assert held["published"] == false
    refute inspect(held) =~ "sk-"
  end

  test "cannot start production publication without a passing decision" do
    assert {:ok, decision} = Decision.record(decision: "fail")
    assert {:error, :release_decision_not_passed} = Publish.plan(decision)
  end

  test "refuses to publish directly even when publish is requested" do
    assert {:ok, plan} = Publish.from_decision()
    assert {:error, :protected_workflow_required} = Publish.execute(plan, publish: true)
  end
end
