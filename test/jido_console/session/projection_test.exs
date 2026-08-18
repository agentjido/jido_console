defmodule Jido.Console.Session.ProjectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Projection, Request}
  alias Jidoka.Event

  test "the mapping covers every approved Jidoka event" do
    mapping = Projection.mapping()

    assert Map.keys(mapping) |> Enum.sort() == Event.events() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    Enum.each(Event.events(), fn event_name ->
      request_id = "req_#{event_name}"
      event = Event.build(event_name, [], request_id: request_id, seq: 0)
      result = Projection.project(event, sequence: 1, session_id: "ses_mapping")

      if event_name in Event.Order.terminal_events() do
        assert {:hold_terminal, _candidate, _cursor} = result
      else
        assert {:ok, projected, cursor} = result
        assert projected["type"] == mapped_type(mapping[Atom.to_string(event_name)])
        assert cursor.last_sequence == 0
      end
    end)
  end

  test "projection preserves Console and Jidoka identities" do
    session = Identity.new!(:session)

    request = %Request{
      id: "req_console",
      request_id: "req_jidoka",
      run_id: "run_console",
      session_id: session.id,
      generation: session.generation,
      owner_instance_id: session.owner_instance_id
    }

    event =
      Event.build(:effect_started, [],
        request_id: request.request_id,
        seq: 0,
        effect_id: "effect_1",
        operation: "search",
        data: %{turn_id: "turn_1"}
      )

    assert {:ok, console_event, cursor} =
             Projection.project(event, sequence: 3, session: session, request: request)

    assert console_event["payload"]["sequence"] == 3
    assert console_event["payload"]["run_id"] == request.run_id
    assert console_event["payload"]["step_id"] == "effect_1"
    assert console_event["type"] == "tool_started"

    identity_pairs =
      MapSet.new(console_event["payload"]["identities"], &{&1["kind"], &1["id"]})

    assert MapSet.member?(identity_pairs, {"session", session.id})
    assert MapSet.member?(identity_pairs, {"request", request.id})
    assert MapSet.member?(identity_pairs, {"run", request.run_id})
    assert MapSet.member?(identity_pairs, {"jidoka_request", request.request_id})
    assert MapSet.member?(identity_pairs, {"turn", "turn_1"})
    assert MapSet.member?(identity_pairs, {"step", "effect_1"})
    assert Enum.any?(identity_pairs, fn {kind, id} -> kind == "source_event" and String.starts_with?(id, "jsk_") end)
    assert byte_size(hd(cursor.recent).digest) == 32
  end

  test "projection requires one explicit session identity" do
    event = Event.build(:turn_started, [], request_id: "req_session", seq: 0)

    assert {:error, :session_identity_missing, nil} = Projection.project(event, sequence: 1)

    assert {:ok, projected, _cursor} =
             Projection.project(event, sequence: 1, session_id: "ses_explicit")

    assert projected["session_id"] == "ses_explicit"
  end

  test "the cursor detects duplicates, conflicts, gaps, and stale events" do
    session = Identity.new!(:session)
    first = Event.build(:turn_started, [], request_id: "req_order", seq: 0)
    second = Event.build(:llm_delta, [], request_id: "req_order", seq: 1, data: %{delta: "a"})
    assert {:ok, initial_cursor} = Projection.new_cursor("req_order", recent_limit: 2)

    assert {:ok, _event, cursor} =
             Projection.project(first, sequence: 1, session: session, cursor: initial_cursor)

    assert {:ignore, :duplicate, ^cursor} = Projection.project(first, sequence: 2, session: session, cursor: cursor)

    conflicting = Event.build(:llm_delta, [], request_id: "req_order", seq: 0, data: %{delta: "other"})

    assert {:error, :source_event_conflict, ^cursor} =
             Projection.project(conflicting, sequence: 2, session: session, cursor: cursor)

    gap = Event.build(:llm_delta, [], request_id: "req_order", seq: 2)

    assert {:error, :source_sequence_gap, ^cursor} =
             Projection.project(gap, sequence: 2, session: session, cursor: cursor)

    assert {:ok, _event, cursor} = Projection.project(second, sequence: 2, session: session, cursor: cursor)
    third = Event.build(:llm_delta, [], request_id: "req_order", seq: 2)
    assert {:ok, _event, cursor} = Projection.project(third, sequence: 3, session: session, cursor: cursor)

    assert {:error, :stale_source_event, ^cursor} =
             Projection.project(first, sequence: 4, session: session, cursor: cursor)
  end

  test "new cursors start at zero and have fixed limits" do
    projected = %{request_id: "req_bounds", seq: -1, event: "turn_started", terminal?: false, data: %{}}

    assert {:error, :invalid_source_sequence, nil} =
             Projection.project(projected, sequence: 1, session_id: "ses_bounds")

    above_zero = %{projected | seq: 1}

    assert {:error, :source_sequence_gap, %{last_sequence: -1}} =
             Projection.project(above_zero, sequence: 1, session_id: "ses_bounds")

    assert {:error, :projection_cursor_limit} =
             Projection.new_cursor("req_65", active_cursor_count: 64)

    assert {:ok, cursor} = Projection.new_cursor("req_limited", recent_limit: 1000)
    assert cursor.recent_limit == 64
  end

  test "terminal event and result arbitrate in both arrival orders" do
    session = Identity.new!(:session)
    event = Event.build(:turn_finished, [], request_id: "req_terminal", seq: 0)
    identity = %{"session_id" => session.id, "request_id" => "req_terminal", "run_id" => "run_terminal"}

    result = %{
      "type" => "run_completed",
      "fields" => %{"run_id" => "run_terminal", "outcome_id" => "out_terminal", "content" => "done"}
    }

    assert {:hold_terminal, _candidate, event_first} =
             Projection.project(event, sequence: 1, session: session, run_id: "run_terminal")

    assert {:ok, event_first} = Projection.admit_result(event_first, identity, result)
    assert {:ok, final, finalized} = Projection.finalize(event_first)
    assert final["type"] == "run_completed"
    assert final["payload"]["content"] == "done"
    assert finalized.terminal.state == :finalized

    assert {:ok, empty} = Projection.new_cursor("req_terminal")
    assert {:ok, result_first} = Projection.admit_result(empty, identity, result)

    assert {:ignore, :duplicate, ^result_first} =
             Projection.admit_result(result_first, identity, result)

    conflicting = put_in(result, ["fields", "content"], "different")

    assert {:error, :terminal_result_conflict, ^result_first} =
             Projection.admit_result(result_first, identity, conflicting)

    assert {:hold_terminal, _candidate, ready} =
             Projection.project(
               event,
               sequence: 1,
               session: session,
               run_id: "run_terminal",
               cursor: result_first
             )

    assert Projection.terminal_ready?(ready)
    assert {:ok, _final, _cursor} = Projection.finalize(ready)
  end

  test "terminal duplicate and late source data cannot advance the cursor" do
    event = Event.build(:turn_failed, [], request_id: "req_closed", seq: 0)

    assert {:hold_terminal, _candidate, cursor} =
             Projection.project(event, sequence: 1, session_id: "ses_closed")

    assert {:ignore, :duplicate, ^cursor} =
             Projection.project(event, sequence: 1, session_id: "ses_closed", cursor: cursor)

    late = Event.build(:llm_delta, [], request_id: "req_closed", seq: 1)

    assert {:error, :stale_source_event, ^cursor} =
             Projection.project(late, sequence: 1, session_id: "ses_closed", cursor: cursor)

    assert {:error, :stale_source_event, nil} =
             Projection.project(event,
               sequence: 1,
               session_id: "ses_closed",
               jidoka_request_id: "req_closed",
               closed_requests: MapSet.new(["req_closed"])
             )
  end

  test "runtime values and unknown authority data fail before admission" do
    runtime = %{
      request_id: "req_runtime",
      seq: 0,
      event: "turn_started",
      terminal?: false,
      data: %{"owner" => self()}
    }

    assert {:error, :raw_runtime_forbidden, nil} =
             Projection.project(runtime, sequence: 1, session_id: "ses_runtime")

    authority = put_in(runtime, [:data], %{"unknown" => %{"authority" => "admin"}})

    assert {:error, {:unknown_authority_field, ["authority"]}, nil} =
             Projection.project(authority, sequence: 1, session_id: "ses_runtime")
  end

  test "the same input has a byte-equivalent portable result" do
    event = Event.build(:llm_delta, [], request_id: "req_deterministic", seq: 0, data: %{delta: "same"})
    opts = [sequence: 7, session_id: "ses_deterministic", run_id: "run_deterministic"]

    assert Projection.project(event, opts) == Projection.project(event, opts)
  end

  test "projection does not own live Console sequence state" do
    source = File.read!("lib/jido_console/session/projection.ex")
    refute source =~ ":ets"
    refute source =~ "Agent."
    refute source =~ "next_sequence"
  end

  defp mapped_type({:terminal, type}), do: type
  defp mapped_type(type), do: type
end
