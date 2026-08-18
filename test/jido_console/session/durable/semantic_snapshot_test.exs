defmodule Jido.Console.Session.Durable.SemanticSnapshotTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Durable.SemanticSnapshot
  alias Jido.Console.Session.State

  @digest "sha256:" <> String.duplicate("a", 64)

  test "round-trips bounded renderer-neutral state without canonical history" do
    state = %{
      State.new("session-snapshot")
      | sequence: 7,
        history: [%{"id" => "event-secret-history"}],
        queues: %{steering: [%{"id" => "input-one"}], follow_up: []},
        pending_interactions: %{"approval-one" => %{"status" => "pending"}},
        permissions: %{"approval-one" => %{"status" => "pending"}},
        control_state: %{"cancel-one" => %{"status" => "terminal"}},
        active_run: %{"run_id" => "run-one"}
    }

    head = %{generation: 3, sequence: 7, chain_digest: @digest}

    assert {:ok, encoded} = SemanticSnapshot.encode("snapshot-one", state, head, "manual")
    assert encoded.encoded_bytes <= SemanticSnapshot.max_bytes()
    refute encoded.bytes =~ "event-secret-history"
    refute Map.has_key?(encoded.value["state"], "history")

    assert {:ok, decoded} = SemanticSnapshot.decode(encoded.bytes, encoded.digest)
    assert {:ok, restored} = SemanticSnapshot.restore(decoded)
    assert restored.session_id == state.session_id
    assert restored.sequence == state.sequence
    assert restored.queues == state.queues
    assert restored.pending_interactions == state.pending_interactions
    assert restored.permissions == state.permissions
    assert restored.control_state == state.control_state
    assert restored.active_run == state.active_run
    assert restored.history == []

    legacy_value =
      update_in(encoded.value, ["state"], &Map.drop(&1, ~w(pending_interactions permissions control_state)))

    assert {:ok, legacy} = SemanticSnapshot.encode(legacy_value)
    assert {:ok, legacy_restored} = SemanticSnapshot.restore(legacy)
    assert legacy_restored.pending_interactions == %{}
    assert legacy_restored.permissions == %{}
    assert legacy_restored.control_state == %{}
  end

  test "rejects changed digests, unknown fields, invalid reasons, and oversized state" do
    state = State.new("session-invalid")
    head = %{generation: 1, sequence: 0, chain_digest: @digest}
    assert {:ok, encoded} = SemanticSnapshot.encode("snapshot-valid", state, head, "manual")

    assert {:error, :semantic_snapshot_digest_mismatch} =
             SemanticSnapshot.decode(encoded.bytes, "sha256:" <> String.duplicate("b", 64))

    assert {:error, :invalid_semantic_snapshot_fields} =
             encoded.value |> Map.put("unknown", true) |> SemanticSnapshot.encode()

    assert {:error, :invalid_semantic_snapshot_reason} =
             encoded.value |> Map.put("reason", "unsafe") |> SemanticSnapshot.encode()

    sensitive = %{state | queues: %{steering: [%{"api_key" => "CANARY"}], follow_up: []}}

    assert {:error, {:sensitive_value_rejected, %{"redacted" => true}}} =
             SemanticSnapshot.encode("snapshot-sensitive", sensitive, head, "manual")

    oversized = %{
      state
      | queues: %{steering: [%{"content" => String.duplicate("x", 1_048_576)}], follow_up: []}
    }

    assert {:error, {:semantic_snapshot_too_large, bytes, 1_048_576}} =
             SemanticSnapshot.encode("snapshot-large", oversized, head, "manual")

    assert bytes > 1_048_576
  end
end
