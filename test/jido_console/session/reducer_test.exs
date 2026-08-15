defmodule Jido.Console.Session.ReducerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Event, Identity, Reducer, State}

  test "live reduction and replay produce the same transcript and outcomes" do
    session = Identity.new!(:session)
    events = [classified(session, "run_started", 1), classified(session, "run_completed", 2)]

    {:ok, live} = reduce(State.new(session), events)
    {:ok, replayed} = Reducer.replay(events, State.new(session))

    assert live.transcript == replayed.transcript
    assert live.outcomes == replayed.outcomes
    assert live.sequence == 2
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
  end

  defp reduce(state, events), do: Reducer.replay(events, state)

  defp classified(session, type, sequence) do
    {:ok, event} =
      Event.classify(%{
        type: type,
        id: "plt_event_#{sequence}",
        session_id: session.id,
        sequence: sequence,
        durability: "process",
        sensitivity: "public",
        origin: %{kind: "session", actor_id: session.id},
        trust: %{evidence: "test", policy: "session-owner"},
        identities: [Identity.to_protocol(session)]
      })

    event
  end
end
