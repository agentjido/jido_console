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

  test "normalizes uncommon records and keeps all collections bounded" do
    turn = Turn.new(5, "bounded", :invalid_context)
    assert turn.attachments == []
    assert Turn.put_changes(turn, :invalid).changes == []

    normalized = Turn.put_changes(turn, [%URI{path: "/value"}, :plain]).changes
    assert Enum.any?(normalized, &match?(%{path: "/value"}, &1))
    assert Enum.any?(normalized, &match?(%{summary: ":plain"}, &1))

    changes = normalized ++ Enum.map(1..100, &%{index: &1})
    turn = Turn.put_changes(turn, changes)
    assert length(turn.changes) == 100
    refute Enum.any?(turn.changes, &match?(%{path: "/value"}, &1))

    reviews = [
      %{interrupt_id: "atom-interrupt", operation: "one"},
      %{"interrupt_id" => "string-interrupt", "operation" => "two"},
      %{id: "atom-id", operation: "three"},
      %{"id" => "string-id", "operation" => "four"},
      %URI{path: "/review"},
      :plain_review
    ]

    turn = Turn.put_reviews(turn, reviews)
    assert length(turn.reviews) == 6
    assert Enum.all?(turn.reviews, &(&1.status == :pending))

    turn = Turn.put_reviews(turn, [%{interrupt_id: "atom-interrupt", operation: "updated"}])
    assert length(turn.reviews) == 6
    assert Enum.find(turn.reviews, &(&1.id == "atom-interrupt")).operation == "updated"

    turn = Turn.decide_review(turn, %{interrupt_id: "atom-interrupt"}, :approve)
    failed = Turn.fail_review(turn, "approval expired")
    assert Enum.find(failed.reviews, &(&1.id == "atom-interrupt")).status == :expired
    assert Turn.fail_review(Turn.new(6, "none"), "failure").reviews == []

    event = %EventProjection{
      id: :unhandled,
      request_id: "request-1",
      seq: 0,
      event: :unknown,
      kind: :event,
      data: %{}
    }

    turn = Turn.put_request(turn, %{request_id: "request-1"})
    assert {:ok, unchanged} = Turn.apply_event(turn, event)
    assert unchanged.assistant == turn.assistant

    review_event = %{event | id: :review, seq: 1, kind: :review, data: %{summary: "no id"}}
    assert {:ok, turn} = Turn.apply_event(unchanged, review_event)
    assert Enum.any?(turn.reviews, &(&1[:summary] == "no id"))

    turn =
      Enum.reduce(0..200, turn, fn index, current ->
        projection = %EventProjection{
          id: {:tool, index},
          request_id: "request-1",
          seq: index + 2,
          event: :effect_planned,
          kind: :tool,
          data: %{
            id: index,
            operation: "tool",
            status: :planned,
            summary: nil,
            error: nil,
            loop_index: nil
          }
        }

        {:ok, next} = Turn.apply_event(current, projection)
        next
      end)

    assert length(turn.tool_order) == 200
    refute Map.has_key?(turn.tools, 0)
    assert Map.has_key?(turn.tools, 200)
    assert Turn.finish(turn, :completed, nil, reviews: :invalid, changes: :invalid).changes == []
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
