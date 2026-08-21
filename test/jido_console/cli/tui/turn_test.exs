defmodule Jido.Console.Tui.TurnTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.Turn

  test "keeps one portable turn record" do
    turn =
      1
      |> Turn.new("hello")
      |> Turn.put_request(%{request_id: "request-1"})
      |> Turn.finish(:completed, "answer")

    assert turn.request_id == "request-1"
    assert turn.prompt == "hello"
    assert turn.assistant == "answer"
    assert turn.outcome.status == :completed
  end
end
