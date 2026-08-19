defmodule Jido.Console.Session.ContinuityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Continuity

  setup do
    assert {:ok, contract} = Continuity.schema()
    %{contract: contract}
  end

  test "the contract gives every record one owner, class, and durability", %{contract: contract} do
    assert :ok = Continuity.review(contract)
    records = Continuity.records(contract)
    assert length(records) == 47
    assert Enum.uniq_by(records, & &1["name"]) == records

    assert Enum.sort(Enum.uniq_by(records, & &1["class"]) |> Enum.map(& &1["class"])) ==
             ~w(authoritative derived forbidden process_local sensitive)

    assert Enum.all?(records, fn record ->
             is_binary(record["owner"]) and record["owner"] != "" and
               record["durability"] in ~w(durable process forbidden)
           end)

    assert {:ok, %{"owner" => "jidoka_session_store", "class" => "authoritative"}} =
             Continuity.record(contract, "jidoka_session_value")

    assert {:ok, %{"class" => "sensitive", "durability" => "process"}} =
             Continuity.record(contract, "materialized_credential_value")

    assert {:ok, %{"class" => "forbidden", "owner" => "no_owner"}} =
             Continuity.record(contract, "beam_runtime_value")
  end

  test "every acknowledgement names its exact commit or process boundary", %{contract: contract} do
    rules = Continuity.acknowledgements(contract)

    assert Enum.map(rules, & &1["item"]) ==
             ~w(input mutating_command console_event jidoka_checkpoint effect_start effect_result watermark client_output)

    assert Enum.all?(rules, fn rule ->
             is_binary(rule["durable_operation"]) and rule["durable_operation"] != "" and
               rule["required_records"] != [] and is_binary(rule["before"])
           end)

    assert {:ok, %{"durable_operation" => "sqlite_full_commit", "before" => "execution_wakeup"}} =
             Continuity.acknowledgement(contract, "input")

    assert {:ok, %{"durability" => "process", "durable_operation" => "live_attachment_apply"}} =
             Continuity.acknowledgement(contract, "client_output")
  end

  test "generation, recovery, and watermark identities are complete", %{contract: contract} do
    fence = contract["generation_fence"]
    watermark = contract["watermark"]
    lifecycle = contract["recovery_lifecycle"]

    assert fence["required_identity"] ==
             ~w(session_id generation owner_instance_id operation_id)

    assert ~w(worker_result timer storage_reply client_operation watermark_commit fork_completion) --
             fence["fenced_operations"] == []

    assert watermark["verified_commit_order"] == "last"
    assert watermark["exact_resume_state"] == "verified"
    assert length(watermark["required_fields"]) == 13
    assert ["console_committed", "verified"] in watermark["transitions"]
    assert ["console_committed", "repair_required"] in watermark["transitions"]
    assert :ok = Continuity.validate_watermark_transition(contract, "console_committed", "verified")

    assert {:error, {:invalid_watermark_transition, "reserved", "verified"}} =
             Continuity.validate_watermark_transition(contract, "reserved", "verified")

    assert lifecycle["store"] ==
             ~w(validating_home recovering_maintenance migrating_store verifying_store store_ready)

    assert lifecycle["candidate_authority"] == "none"
    assert lifecycle["ready"] == ~w(ready_exact ready_transcript_only)
  end

  test "continuity operations have separate safety and authority rules", %{contract: contract} do
    assert {:ok, exact} = Continuity.operation(contract, "exact_resume")
    assert exact["calls_model_or_tool"] == false
    assert exact["watermark_required"] == "yes"

    assert {:ok, transcript} = Continuity.operation(contract, "transcript_only_resume")
    assert transcript["calls_model_or_tool"] == false
    assert transcript["watermark_required"] == "no"
    assert transcript["authority_rule"] == "read_only_visibly_degraded"

    assert {:ok, retry} = Continuity.operation(contract, "retry")
    assert retry["calls_model_or_tool"] == true
    assert retry["authority_rule"] =~ "new_request"

    for operation <- ~w(repair abandon fork) do
      assert {:ok, %{"name" => ^operation, "authority_rule" => rule}} =
               Continuity.operation(contract, operation)

      assert is_binary(rule) and rule != ""
    end
  end

  test "the file-only layout and all major hard budgets are frozen", %{contract: contract} do
    storage = contract["storage"]
    assert storage["engine_class"] == "sqlite"
    assert storage["adapter_status"] == "qualification_required"
    assert storage["remote_service_allowed"] == false
    assert storage["root"] == "JIDO_HOME/state/sessions/v1"
    assert storage["writer_count"] == 1
    assert storage["sqlite"]["synchronous"] == "FULL"
    assert storage["sqlite"]["write_transaction"] == "BEGIN IMMEDIATE"

    assert {:ok, 4_294_967_296} = Continuity.limit(contract, "state_tree_bytes")
    assert {:ok, 262_144} = Continuity.limit(contract, "active_database_pages")
    assert {:ok, 128} = Continuity.limit(contract, "writer_operations")
    assert {:ok, 10_000} = Continuity.limit(contract, "session_canonical_events")
    assert {:ok, 1_048_576} = Continuity.limit(contract, "history_page_bytes")

    tree_budgets = ~w(
      active_database_budget_bytes
      wal_budget_bytes
      control_file_budget_bytes
      verified_backup_budget_bytes
      verified_archive_budget_bytes
      shared_maintenance_budget_bytes
      unallocated_structural_safety_bytes
    )

    assert Enum.sum(
             Enum.map(tree_budgets, fn name ->
               {:ok, value} = Continuity.limit(contract, name)
               value
             end)
           ) ==
             4_294_967_296
  end

  test "the crash and qualification identities are stable", %{contract: contract} do
    crash_points = contract["crash_points"]
    assert length(crash_points) == 23
    assert Enum.uniq_by(crash_points, & &1["id"]) == crash_points

    assert Enum.any?(
             crash_points,
             &(&1["id"] == "unsafe_dispatch_before_result" and
                 &1["result"] == "uncertain_never_repeat_automatically")
           )

    profile = contract["qualification_profile"]
    assert profile["platform"] == "darwin-arm64"
    assert profile["durable_acknowledgement_p95_ms"] == 250
    assert profile["durable_acknowledgement_max_ms"] == 1000
    assert profile["os_kill_repetitions_per_window"] == 25
  end

  test "invalid contracts and manifests return stable review defects" do
    assert {:error, defects} = Continuity.review(%{})
    assert :continuity_identity_invalid in defects
    assert :continuity_records_missing in defects
    assert :continuity_acknowledgements_missing in defects
    assert :continuity_limits_invalid in defects

    assert {:error, {:unknown_continuity_record, "missing"}} =
             Continuity.record(%{}, "missing")

    assert {:error, {:unknown_continuity_limit, "missing"}} =
             Continuity.limit(%{}, "missing")
  end
end
