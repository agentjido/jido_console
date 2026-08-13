defmodule Jido.Cli.Tui.EventProjectionTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.EventProjection
  alias Jidoka.Event

  test "projects safe assistant, tool, review, and outcome data" do
    delta =
      Event.build(:llm_delta, [],
        request_id: "request-1",
        seq: 0,
        data: %{chunk_type: :content, delta: "\e[31manswer\e[0m\a"}
      )

    assert {:ok, %{kind: :assistant_delta, data: %{text: "answer"}}} =
             EventProjection.project(delta)

    tool =
      Event.build(:effect_planned, [],
        request_id: "request-1",
        seq: 1,
        effect_id: "effect-1",
        effect_kind: :operation,
        operation: "\e[32mread_file\e[0m",
        data: %{summary: "\e[2Junsafe"}
      )

    assert {:ok,
            %{
              kind: :tool,
              data: %{id: "effect-1", operation: "read_file", status: :planned, summary: summary}
            }} = EventProjection.project(tool)

    refute summary =~ "\e"

    review =
      Event.build(:approval_requested, [],
        request_id: "request-1",
        seq: 2,
        operation: "write_file",
        data: %{interrupt_id: "review-1", reason: "\e[31mmanual\e[0m"}
      )

    assert {:ok,
            %{
              kind: :review,
              data: %{id: "review-1", operation: "write_file", reason: "manual"}
            }} = EventProjection.project(review)

    terminal = Event.build(:turn_finished, [], request_id: "request-1", seq: 3)
    assert {:ok, %{kind: :outcome, data: %{status: :completed}}} = EventProjection.project(terminal)
  end

  test "rejects events without stable request identity" do
    assert {:error, {:invalid_event_request_id, nil}} =
             Event.build(:turn_started, []) |> EventProjection.project()

    invalid_sequence = %{Event.build(:turn_started, [], request_id: "request-1") | seq: -1}
    assert {:error, {:invalid_event_sequence, -1}} = EventProjection.project(invalid_sequence)

    assert {:error, :invalid_jidoka_event} = EventProjection.project(%{})
  end
end
