defmodule Jido.Console.Release.PublishTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Decision, Publish}

  test "uses a validated passing decision as the publication authority" do
    assert {:ok, decision} = decision()
    assert {:ok, plan} = Publish.plan(decision)
    assert plan["version"] == Decision.version(decision)
    assert plan["published"] == false

    assert {:ok, held} = Publish.execute(decision)
    assert held["status"] == "held"
    assert held["published"] == false
    refute inspect(held) =~ "sk-"
  end

  test "rejects forged decision and publication maps" do
    forged_decision = %{"decision" => "pass", "version" => Jido.Console.Release.Identity.version()}
    forged_plan = %{"decision" => "pass", "published" => false}

    assert {:error, :invalid_release_decision} = Publish.plan(forged_decision)
    assert {:error, :invalid_release_decision} = Publish.execute(forged_plan)
  end

  test "rejects blocked, failed, and changed decisions" do
    assert {:ok, blocked} = Decision.record()
    assert {:error, {:release_decision_not_passed, :blocked}} = Publish.plan(blocked)

    failed_reviews = put_in(reviews(), ["jido_console-m1e01", "result"], "fail")
    assert {:ok, failed} = decision(reviews: failed_reviews)
    assert {:error, {:release_decision_not_passed, :fail}} = Publish.plan(failed)

    assert {:ok, passing} = decision()
    tampered = %{passing | status: :fail}
    assert {:error, :invalid_release_decision} = Publish.plan(tampered)
  end

  test "refuses direct publication even with validated authority" do
    assert {:ok, decision} = decision()
    assert {:error, :protected_workflow_required} = Publish.execute(decision, publish: true)
  end

  defp decision(overrides \\ []) do
    defaults = [reviews: reviews(), channels: channels(), critical_defects: []]
    Decision.record(Keyword.merge(defaults, overrides))
  end

  defp reviews do
    Map.new(Decision.epics(), &{&1, %{"result" => "pass", "proof" => "beadwork:" <> &1}})
  end

  defp channels do
    Enum.map(~w(archive homebrew npm), fn name ->
      %{
        "schema" => "jido.channel-lifecycle",
        "schema_version" => 1,
        "channel" => name,
        "status" => "pass",
        "payload_identity" => %{
          "checksum" => String.duplicate("a", 64),
          "provenance" => %{"source" => "test"},
          "version" => Jido.Console.Release.Identity.version(),
          "license" => "Apache-2.0"
        },
        "stages" => Enum.map(~w(install first_run update remove), &%{"stage" => &1, "status" => "pass"})
      }
    end)
  end
end
