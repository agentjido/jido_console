defmodule Jido.Console.Session.ProjectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Projection}
  alias Jidoka.Event

  test "projects Jidoka events through one boundary and preserves identities" do
    session = Identity.new!(:session)
    event = Event.build(:turn_finished, [], request_id: "req_proj", seq: 0, data: %{turn_id: "trn_1"})

    assert {:ok, console_event} = Projection.project(event, sequence: 3, session: session)
    assert console_event["payload"]["sequence"] == 3
    assert console_event["payload"]["request_id"] == "req_proj"
    assert console_event["type"] == "run_completed"
    assert console_event["id"] == "plt_req_proj_0"

    hibernated = Event.build(:turn_hibernated, [], request_id: "req_pause", seq: 1)
    assert {:ok, paused} = Projection.project(hibernated, sequence: 4, session: session)
    assert paused["type"] == "run_progress"
    assert paused["id"] == "plt_req_pause_1"

    failed = Event.build(:turn_failed, [], request_id: "req_fail", seq: 2)
    assert {:ok, failed_event} = Projection.project(failed, sequence: 5, session: session)
    assert failed_event["type"] == "run_failed"
    assert failed_event["id"] != console_event["id"]
  end

  test "duplicate Jidoka events are ignored and invalid order fails" do
    session = Identity.new!(:session)
    event = Event.build(:llm_delta, [], request_id: "req_dup", seq: 1)
    seen = MapSet.new([{"req_dup", 1}])

    assert {:ignore, :duplicate} = Projection.project(event, sequence: 1, session: session, seen: seen)

    assert {:error, {:invalid_jidoka_order, 0, 2}} =
             Projection.project(
               Event.build(:llm_delta, [], request_id: "req_dup", seq: 2),
               sequence: 1,
               session: session,
               last_jidoka_seq: 0
             )
  end

  test "projection does not own live Console sequence state" do
    source = File.read!("lib/jido_console/session/projection.ex")
    refute source =~ ":ets"
    refute source =~ "Agent."
    refute source =~ "next_sequence"
  end
end
