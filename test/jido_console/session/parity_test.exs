defmodule Jido.Console.Session.ParityTest do
  use ExUnit.Case, async: false

  alias Jido.Console.TestSupport.CurrentClientParity, as: Parity

  test "all production client adapters keep one ordered semantic ledger" do
    fixture = Parity.fixture!()

    results =
      Map.new(Parity.surfaces(), fn surface ->
        {surface, Parity.run_surface!(surface, fixture)}
      end)

    ledgers = results |> Map.values() |> Enum.map(& &1.ledger)
    fingerprints = results |> Map.values() |> Enum.map(& &1.fingerprint) |> Enum.uniq()
    side_effects = results |> Map.values() |> Enum.map(& &1.side_effects) |> Enum.uniq()

    assert Enum.uniq(ledgers) == [results.tui.ledger]
    assert Enum.map(results.tui.ledger, & &1["type"]) == fixture["expected_types"]
    assert [_fingerprint] = fingerprints
    assert results.tui.fingerprint == fixture["expected_fingerprint"]
    assert [effects] = side_effects

    assert effects == %{
             "content" => fixture["content"],
             "permission" => "approved",
             "terminal" => "run_completed",
             "tool" => fixture["tool"]["operation"]
           }

    assert results.tui.renderer =~ fixture["content"]
    assert results.tui.renderer =~ fixture["tool"]["operation"]
    assert results.automation.renderer == fixture["expected_types"]
    assert results.text.renderer =~ "run_completed"
    assert Enum.map(results.json.renderer, & &1["type"]) == fixture["expected_types"]
  end

  test "cancellation and canonical control output match for all adapters" do
    fixture = Parity.fixture!()

    outcomes =
      Map.new(Parity.surfaces(), fn surface ->
        {surface, Parity.control_surface!(surface, fixture)}
      end)

    assert outcomes.tui == outcomes.automation
    assert outcomes.tui == outcomes.text
    assert outcomes.tui == outcomes.json
    assert outcomes.tui.types == ["run_started", "control_requested", "control_completed", "run_failed"]
    assert outcomes.tui.control == "ok"
    assert outcomes.tui.terminal == "cancelled"
  end

  test "attach, gap recovery, stale completion, and detach match for all adapters" do
    fixture = Parity.fixture!()

    outcomes =
      Map.new(Parity.surfaces(), fn surface ->
        {surface, Parity.lifecycle_surface!(surface, fixture)}
      end)

    assert outcomes.tui == outcomes.automation
    assert outcomes.tui == outcomes.text
    assert outcomes.tui == outcomes.json

    assert outcomes.tui == %{
             gap: "gap",
             recovery: "recovery_snapshot",
             suffix: "recovery_suffix",
             stale_completion: {:error, :stale_completion_token},
             receipt: "recovery_receipt",
             detached: {:error, :not_attached}
           }
  end

  test "the public TUI entry renders the same provider-free corpus" do
    fixture = Parity.fixture!()
    frame = Parity.run_tui_entry!(fixture)

    assert frame =~ fixture["content"]
    assert frame =~ fixture["tool"]["operation"]
    assert frame =~ "idle · Enter sends"
  end

  test "public run and eval paths use the pinned replay without a live provider" do
    fixture = Parity.fixture!()
    outcomes = Parity.run_automation_paths!(fixture)

    for {_path, outcome} <- outcomes do
      assert outcome.record["schema"] == "jido.case-result"
      assert outcome.record["schema_version"] == 1
      assert outcome.record["execution"]["status"] == "ok"
      assert outcome.record["evaluation"]["status"] == "passed"
      assert outcome.record["capability_replay"]["status"] == "matched"

      assert outcome.record["capability_replay"]["fixture_digest"] ==
               fixture["automation"]["replay_digest"]

      assert "manifest.json" in outcome.artifacts
      assert "results.jsonl" in outcome.artifacts
      assert "summary.json" in outcome.artifacts
    end
  end
end
