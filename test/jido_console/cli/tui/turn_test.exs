defmodule Jido.Console.Tui.TurnTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.Turn
  alias Jido.Console.Tui.Turn.Tool

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

  test "projects assistant text and operation lifecycle without tool arguments or results" do
    turn = Turn.new(1, "inspect") |> Turn.put_request(%{request_id: "request-1"})

    projections = [
      projection(0, "effect_planned", status: "planned", data: %{"arguments" => "secret-input"}),
      projection(1, "effect_started", status: "started"),
      projection(2, "llm_delta", data: %{"chunk_type" => "thinking", "delta" => "private reasoning"}),
      projection(3, "llm_delta", data: %{"chunk_type" => "content", "delta" => "Visible answer."})
    ]

    turn = Turn.apply_stream(turn, projections)

    assert %Tool{operation: "coding.read", status: :running, summary: nil, error: nil} =
             turn.tools["effect-1"]

    assert turn.assistant == "Visible answer."
    refute inspect(turn) =~ "secret-input"
    refute inspect(turn) =~ "private reasoning"
  end

  test "marks unfinished operation events with the terminal turn outcome" do
    running =
      1
      |> Turn.new("inspect")
      |> Turn.put_request(%{request_id: "request-1"})
      |> Turn.apply_stream([projection(0, "effect_started", status: "started")])

    assert %Tool{status: :cancelled} = Turn.finish(running, :cancelled, nil).tools["effect-1"]
    assert %Tool{status: :failed} = Turn.finish(running, :failed, nil).tools["effect-1"]
  end

  test "restores completed tool identity without retaining durable arguments or results" do
    turn =
      Turn.new(1, "inspect")
      |> Turn.restore_tool_calls([
        %{"provider_call_id" => "call-1", "name" => "coding.read", "arguments" => %{"token" => "secret"}}
      ])
      |> Turn.restore_tool_result(%{
        "tool_call_id" => "call-1",
        "operation" => "coding.read",
        "content" => "private file contents"
      })

    assert %Tool{operation: "coding.read", status: :completed} = turn.tools["call-1"]
    refute inspect(turn) =~ "secret"
    refute inspect(turn) =~ "private file contents"
  end

  defp projection(sequence, event, opts) do
    %{
      request_id: "request-1",
      seq: sequence,
      event: event,
      terminal?: false,
      effect_id: "effect-1",
      effect_kind: if(event == "llm_delta", do: "llm", else: "operation"),
      operation: if(event == "llm_delta", do: nil, else: "coding.read"),
      loop_index: 0,
      status: Keyword.get(opts, :status),
      data: Keyword.get(opts, :data, %{})
    }
  end
end
