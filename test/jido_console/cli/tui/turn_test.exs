defmodule Jido.Console.Tui.TurnTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{EventProjection, Turn}
  alias Jidoka.Event

  test "rejects stale, duplicate, and out-of-order events" do
    turn = Turn.new(0, "prompt") |> Turn.put_request(%{request_id: "request-1"})
    current = projection(:llm_delta, "request-1", 1, data: %{chunk_type: :content, delta: "one"})
    assert {:ok, turn} = Turn.apply_event(turn, current)
    assert turn.assistant == "one"

    assert {:ignore, :duplicate} = Turn.apply_event(turn, current)

    older = projection(:llm_delta, "request-1", 0, data: %{chunk_type: :content, delta: "old"})
    assert {:ignore, :out_of_order} = Turn.apply_event(turn, older)

    stale = projection(:llm_delta, "request-2", 2, data: %{chunk_type: :content, delta: "stale"})
    assert {:ignore, :stale_request} = Turn.apply_event(turn, stale)
    assert turn.assistant == "one"
  end

  test "keeps parallel effects distinct by effect id" do
    turn = Turn.new(0, "prompt") |> Turn.put_request(%{request_id: "request-1"})

    first = tool_projection(:effect_planned, 0, "effect-a")
    second = tool_projection(:effect_planned, 1, "effect-b")
    running = tool_projection(:capability_call_started, 2, "effect-a")
    completed = tool_projection(:capability_call_completed, 3, "effect-a")

    assert {:ok, turn} = Turn.apply_event(turn, first)
    assert {:ok, turn} = Turn.apply_event(turn, second)
    assert {:ok, turn} = Turn.apply_event(turn, running)
    assert {:ok, turn} = Turn.apply_event(turn, completed)

    assert turn.tool_order == ["effect-a", "effect-b"]
    assert turn.tools["effect-a"].status == :completed
    assert turn.tools["effect-b"].status == :planned
    assert Enum.map(turn.tools["effect-a"].events, & &1.status) == [:planned, :running, :completed]
  end

  test "records bounded attachment metadata, reviews, changes, and outcome" do
    context = %{
      "coding" => %{
        "files" => [
          %{
            "path" => "\e[31mlib/value.ex\e[0m",
            "content" => "not retained",
            "size" => 12,
            "sha256" => "sha256:value"
          }
        ]
      }
    }

    turn = Turn.new(4, "change it", context) |> Turn.put_request(%{request_id: "request-1"})
    assert turn.attachments == [%{"path" => "lib/value.ex", "size" => 12, "sha256" => "sha256:value"}]

    review =
      projection(:approval_requested, "request-1", 0,
        operation: "write_file",
        data: %{interrupt_id: "review-1", reason: "manual"}
      )

    assert {:ok, turn} = Turn.apply_event(turn, review)

    turn =
      Turn.finish(turn, :completed, "\e[32mdone\e[0m", changes: [%{"path" => "\e[31mlib/value.ex\e[0m"}])

    assert turn.assistant == "done"
    assert turn.outcome.status == :completed
    assert turn.reviews |> hd() |> Map.fetch!(:id) == "review-1"
    assert turn.changes == [%{"path" => "lib/value.ex"}]
  end

  defp tool_projection(event, seq, effect_id) do
    projection(event, "request-1", seq,
      effect_id: effect_id,
      effect_kind: :operation,
      operation: "read_file"
    )
  end

  defp projection(event, request_id, seq, attrs) do
    event
    |> Event.build([], Keyword.merge([request_id: request_id, seq: seq], attrs))
    |> EventProjection.project()
    |> then(fn {:ok, projection} -> projection end)
  end
end
