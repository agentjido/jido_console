defmodule Jido.Console.Session.ReducerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Event, Identity, Reducer, State}

  test "mixed-event replay derives ordered views from the canonical history" do
    session = Identity.new!(:session)

    events = [
      classified(session, "run_started", 1),
      classified(session, "model_delta", 2),
      classified(session, "control_requested", 3),
      classified(session, "queue_changed", 4, %{
        "queue" => "steering",
        "items" => [%{"id" => "input_1", "content" => "revise"}]
      }),
      classified(session, "control_completed", 5),
      classified(session, "run_completed", 6)
    ]

    {:ok, live} = reduce(State.new(session), events)
    {:ok, replayed} = Reducer.replay(events, State.new(session))
    live_protocol = State.to_protocol(live)
    replayed_protocol = State.to_protocol(replayed)

    assert live == replayed
    assert live.history == events
    assert live.sequence == 6
    assert live.active_run == nil
    assert live.queues.steering == [%{"id" => "input_1", "content" => "revise"}]
    assert live_protocol == replayed_protocol
    assert Enum.map(live_protocol["transcript"], & &1["type"]) == ~w(run_started model_delta run_completed)
    assert Enum.map(live_protocol["outcomes"], & &1["type"]) == ~w(run_completed)
    assert Enum.map(live_protocol["controls"], & &1["type"]) == ~w(control_requested control_completed)

    for view <- ~w(transcript outcomes controls), event <- live_protocol[view] do
      assert event in live_protocol["history"]
    end

    refute Map.has_key?(live, :transcript)
    refute Map.has_key?(live, :outcomes)
    refute Map.has_key?(live, :controls)
    assert Reducer.snapshot(live)["payload"]["state"]["session_id"] == session.id
  end

  test "duplicate, invalid-order, and cross-session events fail closed" do
    session = Identity.new!(:session)
    first = classified(session, "run_started", 1)
    {:ok, state} = Reducer.apply_event(State.new(session), first)
    assert {:ok, ^state} = Reducer.apply_event(state, first)
    assert {:error, :invalid_event_order} = Reducer.apply_event(state, classified(session, "run_completed", 3))

    other = classified(Identity.new!(:session), "run_completed", 2)
    assert {:error, :cross_session_event} = Reducer.apply_event(state, other)

    assert {:error, :invalid_event_session_id} =
             Reducer.apply_event(state, Map.delete(classified(session, "run_completed", 2), "session_id"))
  end

  test "replay restores pending permissions and terminal cancellation without authority" do
    session = Identity.new!(:session)

    events = [
      classified(session, "permission_requested", 1, %{
        "approval_id" => "approval-one",
        "principal" => "user",
        "scope" => "workspace",
        "effect" => "file-write",
        "expires_at_ms" => 1_000,
        "review" => %{"request_id" => "review-one"}
      }),
      classified(session, "control_requested", 2, %{
        "control_id" => "cancel-one",
        "control" => "cancel"
      }),
      classified(session, "control_completed", 3, %{
        "control_id" => "cancel-one",
        "result" => "cancelled"
      })
    ]

    assert {:ok, restored} = Reducer.replay(events, State.new(session))
    assert restored.pending_interactions["approval-one"]["status"] == "pending"
    assert restored.permissions["approval-one"]["effect"] == "file-write"
    assert restored.control_state["cancel-one"]["status"] == "terminal"
    assert restored.control_state["cancel-one"]["result"] == "cancelled"
    refute Map.has_key?(restored, :runtime)
  end

  test "raw events with missing, mixed, or foreign identities cannot enter history" do
    session = Identity.new!(:session)
    state = State.new(session)
    event = classified(session, "run_started", 1)

    missing = update_in(event, ["payload"], &Map.delete(&1, "identities"))

    mixed =
      update_in(event, ["payload", "identities"], fn identities ->
        identities ++ [%{"kind" => "request", "id" => "req_foreign", "session_id" => "ses_foreign"}]
      end)

    foreign =
      put_in(event, ["payload", "identities"], [
        %{"kind" => "session", "id" => "ses_foreign", "session_id" => session.id}
      ])

    assert {:error, {:missing_protocol_fields, "event", "run_started", ["identities"]}} =
             Reducer.apply_event(state, missing)

    assert {:error, :event_identity_mismatch} = Reducer.apply_event(state, mixed)
    assert {:error, :event_identity_mismatch} = Reducer.apply_event(state, foreign)
    assert state.history == []

    {:ok, admitted} = Reducer.apply_event(state, event)

    assert {:error, _reason} = Reducer.apply_event(admitted, missing)
    assert admitted.history == [event]
  end

  test "replay rejects missing, mixed, and foreign identities before history changes" do
    session = Identity.new!(:session)
    first = classified(session, "run_started", 1)
    second = classified(session, "run_completed", 2)

    invalid_events = [
      update_in(second, ["payload"], &Map.delete(&1, "identities")),
      update_in(second, ["payload", "identities"], fn identities ->
        identities ++ [%{"kind" => "request", "id" => "req_foreign", "session_id" => "ses_foreign"}]
      end),
      put_in(second, ["payload", "identities"], [
        %{"kind" => "session", "id" => "ses_foreign", "session_id" => session.id}
      ])
    ]

    for invalid <- invalid_events do
      assert {:error, _reason} = Reducer.replay([first, invalid], State.new(session))
    end
  end

  defp reduce(state, events), do: Reducer.replay(events, state)

  defp classified(session, type, sequence, extra \\ %{}) do
    {:ok, event} =
      %{
        type: type,
        id: "plt_event_#{sequence}",
        session_id: session.id,
        sequence: sequence,
        durability: "process",
        sensitivity: "public",
        origin: %{kind: "session", actor_id: session.id},
        trust: %{evidence: "test", policy: "session-owner"},
        identities: [Identity.to_protocol(session)]
      }
      |> Map.merge(extra)
      |> Event.classify()

    event
  end
end
