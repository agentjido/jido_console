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

    assert {:error, :cross_session_event} =
             Reducer.apply_event(state, Map.delete(classified(session, "run_completed", 2), "session_id"))
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
