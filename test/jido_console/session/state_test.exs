defmodule Jido.Console.Session.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, State}

  test "initial state has explicit data-only semantic fields" do
    session = Identity.new!(:session)
    state = State.new(session)

    assert state.session_id == session.id
    assert state.sequence == 0
    assert state.history == []
    assert state.queues == %{steering: [], follow_up: []}
    assert state.active_run == nil
    refute Map.has_key?(state, :transcript)
    refute Map.has_key?(state, :outcomes)
    refute Map.has_key?(state, :controls)
    assert :ok = State.validate(state)

    protocol = State.to_protocol(state)
    assert protocol["transcript"] == []
    assert protocol["outcomes"] == []
    assert protocol["controls"] == []
    assert {:ok, _} = Jason.encode(protocol)
  end

  test "recursive validation rejects renderer and live runtime values" do
    state = State.new("ses_state")

    assert {:error, {:renderer_value_forbidden, ["history", 0, "draft"]}} =
             State.validate(put_in(state.history, [%{"draft" => "unsent"}]))

    assert {:error, :live_runtime_forbidden} =
             State.validate(put_in(State.new("ses_state").history, [%{"owner" => self()}]))
  end
end
