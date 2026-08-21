defmodule Jido.Console.Tui.ActivityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{Activity, Turn}

  test "reads public request identity from active work" do
    request = %{queue_item_id: "item-1", request_id: "request-1"}
    turn = %{Turn.new(1, "prompt") | assistant: "partial"}
    activity = {:active, request, turn, :streaming}

    assert Activity.tag(activity) == :active
    assert Activity.request(activity) == request
    assert Activity.turn(activity) == turn
    assert Activity.streaming(activity) == "partial"
  end
end
