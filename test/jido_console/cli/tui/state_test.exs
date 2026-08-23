defmodule Jido.Console.Tui.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.View
  alias Jido.Console.Tui.{Editor, State, Turn}

  test "restores all renderer state from one complete View" do
    view =
      View.new!(
        thread_id: "thread-1",
        status: :running,
        transcript: [%{"role" => "user", "content" => "hello"}],
        history: [],
        history_truncated?: false,
        partial: [%{data: %{text: "part"}}],
        active: %{
          "queue_item_id" => "item-1",
          "request_id" => "request-1",
          "input" => "hello"
        },
        review: nil,
        queue: [],
        resources: %{"status" => "ready"},
        error: nil,
        revision: 4
      )

    state = State.new(nil, {80, 24}) |> State.restore_view(view)

    assert {:active, %{request_id: "request-1"}, %Turn{assistant: "part"}, :streaming} = state.activity
  end

  test "restores active operation states from one complete View" do
    view =
      View.new!(
        thread_id: "thread-1",
        status: :running,
        transcript: [],
        history: [],
        partial: [
          stream_projection(0, "effect_started", "effect-running", "coding.read"),
          stream_projection(1, "effect_failed", "effect-failed", "coding.search"),
          %{
            request_id: "request-1",
            seq: 2,
            event: "llm_delta",
            terminal?: false,
            effect_kind: "llm",
            data: %{"chunk_type" => "content", "delta" => "I found the gap."}
          }
        ],
        active: %{
          "queue_item_id" => "item-1",
          "request_id" => "request-1",
          "input" => "inspect"
        },
        review: nil,
        queue: [],
        resources: %{"status" => "ready"},
        error: nil,
        revision: 3
      )

    state = State.new(nil, {80, 24}) |> State.restore_view(view)

    assert {:active, _request, %Turn{} = turn, :streaming} = state.activity
    assert turn.assistant == "I found the gap."
    assert turn.tools["effect-running"].status == :running
    assert turn.tools["effect-failed"].status == :failed
    assert turn.tool_order == ["effect-running", "effect-failed"]
  end

  test "a complete View restores review authority after Ctrl-C" do
    view = review_view()

    for {key, decision} <- [{"a", :approve}, {"d", :deny}] do
      state = State.new(nil, {80, 24}) |> State.restore_view(view)

      {state, [{:cancel_turn, request}]} = State.update(state, {:terminal, {:key, :ctrl_c}})
      assert request.request_id == "request-1"
      assert {:cancelling, %Turn{}, {:request, ^request}} = state.activity

      state = State.restore_view(state, view)

      assert {:review, restored_request, %Turn{}, restored_review, :awaiting} = state.activity

      assert {_, [{:respond_review, ^decision, ^restored_request, ^restored_review, review}]} =
               State.update(state, {:terminal, {:text, key}})

      assert review.id == "review-1"
    end
  end

  test "a TermUI paste event cannot decide a review" do
    state = State.new(nil, {80, 24}) |> State.restore_view(review_view())

    assert {^state, []} =
             State.update(state, {:terminal, TermUI.Event.paste(String.duplicate("A", 2_000))})
  end

  test "ignores editor input while a review response is pending" do
    state =
      State.new(nil, {30, 12})
      |> State.restore_view(review_view())
      |> Map.put(:editor, Editor.from_text("hidden prompt"))

    {state, [{:respond_review, :approve, _request, _event, _review}]} =
      State.update(state, {:terminal, TermUI.Event.text("a")})

    assert {:review, _request, _turn, _event, {:responding, :approve}} = state.activity

    for event <- [
          TermUI.Event.text("x"),
          TermUI.Event.key(:backspace),
          TermUI.Event.mouse(:press, :left, 2, 7)
        ] do
      assert {^state, []} = State.update(state, {:terminal, event})
    end

    assert Editor.value(state.editor) == "hidden prompt"
  end

  test "restores a failed turn from closing product history" do
    error = "provider failed exactly"
    state = restore_closed_turn("prompt_failed", %{"error" => error})

    assert [%Turn{prompt: "do work", request_id: "request-1", outcome: outcome}] = state.turns
    assert outcome == %{status: :failed, error: error}
  end

  test "restores a legacy tool validation failure as a concise message" do
    legacy = %{
      "category" => "unknown",
      "message" =>
        ~s(%{type: "tuple", values: [:invalid_operation_arguments, "coding.read", %{message: "json schema validation failed\\n\\nat: \\"#/start_line\\"\\n  - value 0 is lower than minimum 1"}]})
    }

    state = restore_closed_turn("prompt_failed", %{"error" => legacy})

    assert [%Turn{outcome: %{status: :failed, error: error}}] = state.turns
    assert error == "The coding.read tool requires start_line to be 1 or greater. Try the task again."
    refute error =~ "invalid_operation_arguments"
  end

  test "restores a cancelled turn from closing product history" do
    error = "cancelled by user"
    state = restore_closed_turn("prompt_cancelled", %{"error" => error})

    assert [%Turn{prompt: "do work", request_id: "request-1", outcome: outcome}] = state.turns
    assert outcome == %{status: :cancelled, error: error}
  end

  test "restores an interrupted turn from closing product history" do
    reason = "owner_replaced"
    state = restore_closed_turn("prompt_interrupted", %{"reason" => reason})

    assert [%Turn{prompt: "do work", request_id: "request-1", outcome: outcome}] = state.turns
    assert outcome == %{status: :interrupted, error: reason}
  end

  test "does not duplicate a successful transcript turn from product history" do
    view =
      closed_view(
        "prompt_succeeded",
        %{"result" => %{"answer" => "done"}},
        transcript: [%{"role" => "user", "content" => "do work"}, %{"role" => "assistant", "content" => "done"}]
      )

    state = State.new(nil, {80, 24}) |> State.restore_view(view)

    assert [%Turn{prompt: "do work", assistant: "done", outcome: %{status: :completed}}] = state.turns
  end

  test "restores the final assistant answer after tool calls" do
    operation =
      Jason.encode!(%{
        "type" => "operations",
        "operations" => [%{"name" => "coding.read", "arguments" => %{"path" => "AGENTS.md"}}]
      })

    view =
      closed_view(
        "prompt_succeeded",
        %{"result" => "final answer"},
        transcript: [
          %{"role" => "user", "content" => "explain this repo"},
          %{
            "role" => "assistant",
            "content" => operation,
            "tool_calls" => [
              %{
                "provider_call_id" => "call-1",
                "name" => "coding.read",
                "arguments" => %{"token" => "secret"}
              }
            ]
          },
          %{
            "role" => "tool",
            "tool_call_id" => "call-1",
            "operation" => "coding.read",
            "content" => "repository instructions"
          },
          %{"role" => "assistant", "content" => "final answer"}
        ]
      )

    state = State.new(nil, {80, 24}) |> State.restore_view(view)

    assert [
             %Turn{
               prompt: "explain this repo",
               assistant: "final answer",
               outcome: %{status: :completed},
               tool_order: ["call-1"]
             } = turn
           ] = state.turns

    assert turn.tools["call-1"].operation == "coding.read"
    assert turn.tools["call-1"].status == :completed
    refute inspect(turn) =~ "secret"
    refute inspect(turn) =~ "repository instructions"
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert Enum.find(state.messages, &(&1.role == :tool)).content == ""
  end

  test "uses the successful result when the final transcript answer is absent" do
    view =
      closed_view(
        "prompt_succeeded",
        %{"result" => %{"content" => "stored final answer"}},
        transcript: [
          %{"role" => "user", "content" => "do work"},
          %{
            "role" => "assistant",
            "content" => ~s({"type":"operations","operations":[]}),
            "tool_calls" => [%{"name" => "coding.read"}]
          }
        ]
      )

    state = State.new(nil, {80, 24}) |> State.restore_view(view)

    assert [%Turn{assistant: "stored final answer", outcome: %{status: :completed}}] = state.turns
  end

  test "uses atom-keyed content from a successful result" do
    state =
      restore_closed_turn("prompt_succeeded", %{"result" => %{content: "stored final answer"}})

    assert [%Turn{assistant: "stored final answer", outcome: %{status: :completed}}] = state.turns
  end

  test "does not assign a truncated closing event to an unrelated transcript turn" do
    view =
      View.new!(
        thread_id: "thread-1",
        status: :idle,
        transcript: [
          %{"role" => "user", "content" => "older work"},
          %{"role" => "assistant", "content" => "older result"}
        ],
        history: [history_event("prompt_failed", 2, %{"error" => "newer failure"})],
        history_truncated?: true,
        partial: [],
        active: nil,
        review: nil,
        queue: [],
        resources: %{"status" => "ready"},
        error: nil,
        revision: 2
      )

    state = State.new(nil, {80, 24}) |> State.restore_view(view)

    assert [
             %Turn{prompt: "older work", outcome: %{status: :completed}},
             %Turn{prompt: "", outcome: %{status: :failed, error: "newer failure"}}
           ] = state.turns
  end

  test "submits an idle prompt through the command effect" do
    state = State.new(nil, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "hello"}})
    {state, [{:start_turn, "hello"}]} = State.update(state, {:terminal, {:key, :enter}})
    assert state.messages == [%{role: :user, content: "hello"}]
  end

  test "submits another prompt without replacing the active turn" do
    request = %{queue_item_id: "active", request_id: "request-1"}
    turn = Turn.new(0, "active") |> Turn.put_request(request)
    state = %{State.new(nil, {80, 24}) | activity: {:active, request, turn, :streaming}}
    {state, []} = State.update(state, {:terminal, {:text, "queued"}})

    {state, [{:start_turn, "queued"}]} = State.update(state, {:terminal, {:key, :enter}})
    assert {:active, ^request, ^turn, :streaming} = state.activity
    assert Editor.value(state.editor) == ""
  end

  test "does not replay a queued prompt when the restored View reports startup failure" do
    state = State.new(nil, {80, 24}, startup: :starting)
    {state, []} = State.update(state, {:terminal, {:text, "queued during startup"}})
    {state, [{:start_turn, "queued during startup"}]} = State.update(state, {:terminal, {:key, :enter}})

    {state, effects} = State.runtime_ready(state, :session_client, reconciling_view())

    assert effects == []
    assert {:ok, :thread_reconciling} = State.startup_failure(state)
  end

  test "keeps TermUI modifiers and returns selected text for clipboard output" do
    state = State.new(nil, {80, 24})
    {state, []} = State.update(state, {:terminal, TermUI.Event.text("hello")})
    {state, []} = State.update(state, {:terminal, TermUI.Event.key(:left, modifiers: [:shift])})
    {state, []} = State.update(state, {:terminal, TermUI.Event.key(:left, modifiers: [:shift])})

    assert {state, [{:copy, "lo"}]} =
             State.update(state, {:terminal, TermUI.Event.key("c", modifiers: [:ctrl])})

    assert Editor.value(state.editor) == "hello"
  end

  test "an unselected TermUI Ctrl-C event cancels the active turn" do
    request = %{queue_item_id: "active", request_id: "request-1"}
    turn = Turn.new(0, "active") |> Turn.put_request(request)
    state = %{State.new(nil, {80, 24}) | activity: {:active, request, turn, :streaming}}

    assert {state, [{:cancel_turn, ^request}]} =
             State.update(state, {:terminal, TermUI.Event.key("c", modifiers: [:ctrl])})

    assert {:cancelling, ^turn, {:request, ^request}} = state.activity
  end

  test "routes prompt mouse coordinates into TextArea selection" do
    state = State.new(nil, {30, 12})
    {state, []} = State.update(state, {:terminal, TermUI.Event.text("hello")})
    prompt_y = 12 - 5

    {state, []} =
      State.update(state, {:terminal, TermUI.Event.mouse(:press, :left, 2, prompt_y)})

    {state, []} =
      State.update(state, {:terminal, TermUI.Event.mouse(:drag, :left, 7, prompt_y)})

    assert {_state, [{:copy, "hello"}]} =
             State.update(state, {:terminal, TermUI.Event.key("c", modifiers: [:ctrl])})
  end

  defp restore_closed_turn(type, payload) do
    view = closed_view(type, payload, transcript: [%{"role" => "user", "content" => "do work"}])
    State.new(nil, {80, 24}) |> State.restore_view(view)
  end

  defp closed_view(type, payload, opts) do
    View.new!(
      thread_id: "thread-1",
      status: :idle,
      transcript: Keyword.fetch!(opts, :transcript),
      history: [
        history_event("prompt_queued", 1, %{"input" => "do work"}),
        history_event(type, 2, payload)
      ],
      history_truncated?: false,
      partial: [],
      active: nil,
      review: nil,
      queue: [],
      resources: %{"status" => "ready"},
      error: nil,
      revision: 2
    )
  end

  defp review_view do
    View.new!(
      thread_id: "thread-1",
      status: :review,
      transcript: [%{"role" => "user", "content" => "do work"}],
      history: [history_event("prompt_queued", 1, %{"input" => "do work"})],
      history_truncated?: false,
      partial: [],
      active: %{"queue_item_id" => "item-1", "request_id" => "request-1", "input" => "do work"},
      review: %{"id" => "review-1", "operation" => "write_file", "arguments" => %{}},
      queue: [],
      resources: %{"status" => "ready"},
      error: nil,
      revision: 2
    )
  end

  defp reconciling_view do
    View.new!(
      thread_id: "thread-1",
      status: :reconciling,
      transcript: [],
      history: [],
      history_truncated?: false,
      partial: [],
      active: nil,
      review: nil,
      queue: [],
      resources: %{"status" => "recovering"},
      error: nil,
      revision: 1
    )
  end

  defp history_event(type, sequence, payload) do
    %{
      "id" => "item-1:#{type}",
      "sequence" => sequence,
      "queue_item_id" => "item-1",
      "request_id" => "request-1",
      "type" => type,
      "jidoka_revision" => sequence,
      "payload" => payload,
      "committed_at_ms" => sequence
    }
  end

  defp stream_projection(sequence, event, effect_id, operation) do
    %{
      request_id: "request-1",
      seq: sequence,
      event: event,
      terminal?: false,
      effect_id: effect_id,
      effect_kind: "operation",
      operation: operation,
      loop_index: 0,
      status: if(event == "effect_failed", do: "failed", else: "started"),
      data: %{"arguments" => %{"token" => "must-not-render"}}
    }
  end
end
