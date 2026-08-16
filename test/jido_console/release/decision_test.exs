defmodule Jido.Console.Release.DecisionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Decision

  test "passes only with complete passing proof" do
    assert {:ok, decision} = complete_decision()
    assert Decision.status(decision) == :pass
    assert :ok = Decision.validate(decision)

    assert {:ok, %{version: version, decision: "pass", channels: channels}} =
             Decision.authorize_publication(decision)

    assert version == Jido.Console.Release.Identity.version()
    assert channels == ~w(archive homebrew npm)

    record = Decision.to_map(decision)
    assert record["version"] == Jido.Console.Release.Identity.version()
    assert record["decision"] == "pass"
    assert record["durable_session_recovery"] == false
    assert length(record["epics"]) == 28
    assert Enum.all?(record["epics"], &(&1["result"] == "pass"))
    assert Enum.map(record["channels"], & &1["channel"]) == ~w(archive homebrew npm)
    assert record["blocking_reasons"] == []
    assert record["failures"] == []
    refute inspect(record) =~ "sk-"
  end

  test "blocks when an epic review or its proof is missing" do
    reviews = Map.delete(reviews(), "jido_console-m1e01")
    assert {:ok, missing_review} = complete_decision(reviews: reviews)
    assert Decision.status(missing_review) == :blocked

    reviews = put_in(reviews(), ["jido_console-m1e01", "proof"], "")
    assert {:ok, missing_proof} = complete_decision(reviews: reviews)
    assert Decision.status(missing_proof) == :blocked
  end

  test "blocks when a channel proof is missing or invalid" do
    assert {:ok, missing} = complete_decision(channels: Enum.drop(channels(), 1))
    assert Decision.status(missing) == :blocked

    [archive | remaining] = channels()
    tampered = %{archive | "status" => "pass", "stages" => fail_stages()}
    assert {:ok, invalid} = complete_decision(channels: [tampered | remaining])
    assert Decision.status(invalid) == :blocked
  end

  test "fails when a valid epic or channel proof reports failure" do
    reviews = put_in(reviews(), ["jido_console-m1e01", "result"], "fail")
    assert {:ok, failed_review} = complete_decision(reviews: reviews)
    assert Decision.status(failed_review) == :fail

    assert {:error, {:release_decision_not_passed, :fail}} =
             Decision.authorize_publication(failed_review)

    [_archive, homebrew, npm] = channels()
    archive = channel("archive", "fail")
    assert {:ok, failed_channel} = complete_decision(channels: [archive, homebrew, npm])
    assert Decision.status(failed_channel) == :fail
  end

  test "fails when a critical defect is open" do
    defects = [
      %{
        "id" => "release-blocker-1",
        "severity" => "critical",
        "status" => "open",
        "proof" => "beadwork:release-blocker-1"
      }
    ]

    assert {:ok, decision} = complete_decision(critical_defects: defects)
    assert Decision.status(decision) == :fail
    assert Decision.to_map(decision)["failures"] == [~s({:open_critical_defect, "release-blocker-1"})]

    assert {:ok, incomplete} = Decision.record(critical_defects: defects)
    assert Decision.status(incomplete) == :fail
  end

  test "does not accept a caller-supplied result" do
    assert {:error, {:unsupported_decision_inputs, [:decision]}} =
             complete_decision(decision: "pass")
  end

  test "detects a changed decision after validation" do
    assert {:ok, decision} = complete_decision()
    tampered = %{decision | status: :fail}
    assert {:error, :invalid_release_decision} = Decision.validate(tampered)
  end

  test "rejects a forged publication decision directly" do
    forged = %{"decision" => "pass", "version" => Jido.Console.Release.Identity.version()}
    assert {:error, :invalid_release_decision} = Decision.authorize_publication(forged)
  end

  defp complete_decision(overrides \\ []) do
    defaults = [reviews: reviews(), channels: channels(), critical_defects: []]
    Decision.record(Keyword.merge(defaults, overrides))
  end

  defp reviews do
    Map.new(Decision.epics(), &{&1, %{"result" => "pass", "proof" => "beadwork:" <> &1}})
  end

  defp channels do
    Enum.map(~w(archive homebrew npm), &channel/1)
  end

  defp channel(name, status \\ "pass") do
    %{
      "schema" => "jido.channel-lifecycle",
      "schema_version" => 1,
      "channel" => name,
      "status" => status,
      "payload_identity" => %{
        "checksum" => String.duplicate("a", 64),
        "provenance" => %{"source" => "test"},
        "version" => Jido.Console.Release.Identity.version(),
        "license" => "Apache-2.0"
      },
      "stages" => if(status == "pass", do: pass_stages(), else: fail_stages())
    }
  end

  defp pass_stages do
    Enum.map(~w(install first_run update remove), &%{"stage" => &1, "status" => "pass"})
  end

  defp fail_stages do
    [
      %{"stage" => "install", "status" => "fail", "reason" => "test failure"},
      %{"stage" => "first_run", "status" => "not_run"},
      %{"stage" => "update", "status" => "not_run"},
      %{"stage" => "remove", "status" => "not_run"}
    ]
  end
end
