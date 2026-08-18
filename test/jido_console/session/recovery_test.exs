defmodule Jido.Console.Session.RecoveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Delivery, Event, Recovery, Reducer, State}

  @identity %{
    session_id: "ses_1",
    client_id: "cli_1",
    attachment_id: "att_1",
    generation: 1,
    owner_instance_id: "owner-1"
  }

  test "attach returns one bounded canonical snapshot that restores exact state" do
    state = state_with_events(2)

    assert {:ok, snapshot} = Recovery.attach_snapshot(state, @identity)
    assert snapshot["type"] == "attach_snapshot"
    assert snapshot["payload"]["snapshot_sequence"] == 2
    canonical = snapshot["payload"]["snapshot"]
    assert Map.keys(canonical) |> Enum.sort() == ~w(active_run history queues sequence session_id)
    refute Map.has_key?(canonical, "transcript")
    refute Map.has_key?(canonical, "outcomes")
    refute Map.has_key?(canonical, "controls")
    assert {:ok, ^state} = Recovery.restore_snapshot(snapshot)

    encoded_size = snapshot |> Jason.encode!() |> byte_size()
    assert {:ok, _snapshot} = Recovery.attach_snapshot(state, @identity, snapshot_bytes: encoded_size)

    assert {:error, :snapshot_limit_exceeded} =
             Recovery.attach_snapshot(state, @identity, snapshot_bytes: encoded_size - 1)
  end

  test "snapshots reject renderer values, runtime values, and identity mismatches" do
    renderer_state = put_in(State.new("ses_1").history, [%{"draft" => "local"}])
    runtime_state = put_in(State.new("ses_1").history, [%{"owner" => self()}])

    assert {:error, {:renderer_value_forbidden, _path}} =
             Recovery.attach_snapshot(renderer_state, @identity)

    assert {:error, :live_runtime_forbidden} = Recovery.attach_snapshot(runtime_state, @identity)

    assert {:error, :recovery_identity_mismatch} =
             Recovery.attach_snapshot(State.new("ses_1"), %{@identity | session_id: "ses_other"})
  end

  test "snapshot plus contiguous suffix restores owner-equivalent state" do
    initial = state_with_events(1)
    {gapped, gap} = gapped_delivery()
    gap_id = gap["payload"]["gap_id"]

    assert {:ok, recovering, snapshot} =
             Recovery.begin(initial, gapped, @identity, gap_id)

    recovery_token = snapshot["payload"]["recovery_token"]
    assert recovering.status == :recovering
    assert {:error, :delivery_recovering, ^recovering} = Delivery.pull(recovering, @identity)

    event2 = event(2)
    event3 = event(3)
    {:ok, owner} = Reducer.apply_event(initial, event2)
    {:ok, owner} = Reducer.apply_event(owner, event3)
    {:ok, recovering, false} = Delivery.offer(recovering, event2)
    {:ok, recovering, false} = Delivery.offer(recovering, event3)

    assert {:ok, recovering, suffix} =
             Recovery.replay(owner, recovering, @identity, recovery_token)

    assert suffix["payload"]["after_sequence"] == 1
    assert suffix["payload"]["through_sequence"] == 3
    assert Enum.map(suffix["payload"]["events"], & &1["payload"]["sequence"]) == [2, 3]

    assert {:ok, restored} = Recovery.restore_snapshot(snapshot)
    assert {:ok, ^owner} = Recovery.apply_suffix(restored, suffix, @identity)

    completion_token = suffix["payload"]["completion_token"]

    assert {:ok, completed, receipt, false} =
             Recovery.complete(recovering, @identity, completion_token)

    assert completed.status == :open
    assert completed.last_acked == 3
    assert completed.queue == []
    assert receipt["payload"]["through_sequence"] == 3
    assert receipt["payload"]["process_lifetime"]
  end

  test "an empty suffix is valid and later events resume as incremental output" do
    state = state_with_events(1)
    {gapped, gap} = gapped_delivery()

    {:ok, recovering, snapshot} =
      Recovery.begin(state, gapped, @identity, gap["payload"]["gap_id"])

    {:ok, recovering, suffix} =
      Recovery.replay(state, recovering, @identity, snapshot["payload"]["recovery_token"])

    assert suffix["payload"]["events"] == []
    assert suffix["payload"]["after_sequence"] == 1
    assert suffix["payload"]["through_sequence"] == 1

    event2 = event(2)
    {:ok, recovering, false} = Delivery.offer(recovering, event2)

    assert {:ok, open, _receipt, true} =
             Recovery.complete(recovering, @identity, suffix["payload"]["completion_token"])

    assert {:ok, awaiting_ack, batch} = Delivery.pull(open, @identity)
    assert batch["payload"]["events"] == [event2]
    assert awaiting_ack.status == :ack_required
  end

  test "identity, recovery token, completion token, and repeated suffix failures do not mutate state" do
    state = state_with_events(1)
    {gapped, gap} = gapped_delivery()
    {:ok, recovering, snapshot} = Recovery.begin(state, gapped, @identity, gap["payload"]["gap_id"])

    wrong = %{@identity | attachment_id: "att_old"}

    assert {:error, :recovery_identity_mismatch, ^recovering} =
             Recovery.replay(state, recovering, wrong, snapshot["payload"]["recovery_token"])

    assert {:error, :stale_recovery_token, ^recovering} =
             Recovery.replay(state, recovering, @identity, "wrong")

    assert {:ok, replaying, suffix} =
             Recovery.replay(state, recovering, @identity, snapshot["payload"]["recovery_token"])

    assert {:error, :recovery_suffix_already_issued, ^replaying} =
             Recovery.replay(state, replaying, @identity, snapshot["payload"]["recovery_token"])

    assert {:error, :stale_completion_token, ^replaying} =
             Recovery.complete(replaying, @identity, "wrong")

    assert {:ok, open, _receipt, false} =
             Recovery.complete(replaying, @identity, suffix["payload"]["completion_token"])

    assert {:error, :stale_completion_token, ^open} =
             Recovery.complete(open, @identity, suffix["payload"]["completion_token"])
  end

  test "recovery queue overflow creates a new gap and invalidates old tokens" do
    state = state_with_events(1)
    {gapped, gap} = gapped_delivery(limits: %{queue_count: 1})

    {:ok, recovering, snapshot} =
      Recovery.begin(state, gapped, @identity, gap["payload"]["gap_id"])

    {:ok, recovering, _suffix} =
      Recovery.replay(state, recovering, @identity, snapshot["payload"]["recovery_token"])

    {:ok, recovering, false} = Delivery.offer(recovering, event(2))
    old_completion = recovering.recovery.completion_token

    assert {:gap, new_gap_state, new_gap, true} = Delivery.offer(recovering, event(3))
    assert new_gap["payload"]["reason"] == "recovery_queue_overflow"
    assert new_gap["payload"]["gap_id"] != gap["payload"]["gap_id"]
    assert new_gap_state.recovery == nil

    assert {:error, :stale_completion_token, ^new_gap_state} =
             Recovery.complete(new_gap_state, @identity, old_completion)
  end

  test "suffix count, size, order, and future validation fail without partial state" do
    state = state_with_events(3)
    {gapped, gap} = gapped_delivery()
    baseline = state_with_events(1)

    {:ok, recovering, snapshot} =
      Recovery.begin(baseline, gapped, @identity, gap["payload"]["gap_id"])

    token = snapshot["payload"]["recovery_token"]

    assert {:error, :recovery_window_exceeded, ^recovering} =
             Recovery.replay(state, recovering, @identity, token, suffix_count: 1)

    assert {:error, :recovery_window_exceeded, ^recovering} =
             Recovery.replay(state, recovering, @identity, token, suffix_bytes: 100)

    {:ok, recovering, suffix} = Recovery.replay(state, recovering, @identity, token)
    {:ok, restored} = Recovery.restore_snapshot(snapshot)

    missing = put_in(suffix, ["payload", "events"], [])
    duplicate = put_in(suffix, ["payload", "events"], [event(2), event(2)])
    future = put_in(suffix, ["payload", "after_sequence"], 5)

    for invalid <- [missing, duplicate, future] do
      assert {:error, _reason} = Recovery.apply_suffix(restored, invalid, @identity)
      assert restored.sequence == 1
    end

    assert recovering.status == :recovering
  end

  test "recovery is explicitly process-lifetime only" do
    limitation = Recovery.limitation()
    assert limitation =~ "process-lifetime only"
    assert limitation =~ "not application-restart recovery"
    assert limitation =~ "durable"
  end

  defp gapped_delivery(opts \\ []) do
    delivery = delivery(opts)
    {:ok, delivery, true} = Delivery.offer(delivery, event(1))
    {:ok, delivery, batch} = Delivery.pull(delivery, @identity)

    {:gap, gapped, gap, true} =
      Delivery.timeout(delivery, "att_1", delivery.inflight.timer_token, 1)

    assert batch["type"] == "output_batch"
    {gapped, gap}
  end

  defp delivery(opts) do
    Delivery.new(
      Keyword.merge(
        [
          session_id: "ses_1",
          client_id: "cli_1",
          attachment_id: "att_1",
          generation: 1,
          owner_instance_id: "owner-1",
          token_secret: String.duplicate("r", 32)
        ],
        opts
      )
    )
  end

  defp state_with_events(count) do
    Enum.reduce(1..count, State.new("ses_1"), fn sequence, state ->
      {:ok, state} = Reducer.apply_event(state, event(sequence))
      state
    end)
  end

  defp event(sequence) do
    type = if sequence == 1, do: "run_started", else: "model_delta"

    attrs = %{
      type: type,
      id: "event_#{sequence}",
      session_id: "ses_1",
      sequence: sequence,
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "session", actor_id: "ses_1"},
      trust: %{evidence: "test", policy: "test"},
      identities: [%{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"}],
      run_id: "run_1"
    }

    attrs =
      if type == "run_started",
        do: Map.put(attrs, :turn_id, "turn_1"),
        else: Map.put(attrs, :text, "delta_#{sequence}")

    {:ok, event} = Event.classify(attrs)
    event
  end
end
