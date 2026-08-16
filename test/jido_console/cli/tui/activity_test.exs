defmodule Jido.Console.Tui.ActivityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Runtime.Result
  alias Jido.Console.Session.Request
  alias Jido.Console.Tui.{Activity, Turn}

  test "projects and replaces every activity shape" do
    request = %Request{id: "id", request_id: "request", run_id: "run", session_id: "session"}
    turn = %{Turn.new(1, "prompt") | assistant: "stream"}
    replacement = Turn.new(2, "replacement")
    result = Result.error("request", :session, :handle, :failed)

    activities = [
      {:starting, {:turn, turn}},
      {:active, request, turn, :streaming},
      {:review, request, turn, result, :awaiting},
      {:cancelling, turn, {:request, request}}
    ]

    assert Activity.tag(:idle) == :idle
    assert Activity.tag({:preparing, {:prompt, "prompt"}}) == :preparing
    assert Activity.tag({:starting, {:runtime, :empty}}) == :starting
    assert Activity.tag({:failed, :turn, :failed, "message"}) == :failed
    assert Activity.error({:failed, :turn, :failed, "message"}) == "message"
    assert Activity.error(:idle) == nil

    Enum.each(activities, fn activity ->
      assert Activity.turn(activity) == turn
      assert Activity.replace_turn(activity, replacement) |> Activity.turn() == replacement
    end)

    assert Activity.request(Enum.at(activities, 1)) == request
    assert Activity.request(Enum.at(activities, 2)) == request
    assert Activity.request(Enum.at(activities, 3)) == request
    assert Activity.streaming(Enum.at(activities, 1)) == "stream"
    assert Activity.streaming(:idle) == ""
    assert Activity.turn(:idle) == nil
    assert Activity.request(:idle) == nil
    assert Activity.replace_turn(:idle, replacement) == :idle
  end
end
