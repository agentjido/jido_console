defmodule Jido.Cli.Tui.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.State
  alias Jidoka.Cancellation
  alias Jidoka.Event

  test "submits a prompt and commits a streamed result" do
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "hello"}})
    {state, [{:start_turn, "hello"}]} = State.update(state, {:terminal, {:key, :enter}})
    assert state.messages == [%{role: :user, content: "hello"}]

    request = %{request_id: "request-1"}
    {state, []} = State.update(state, {:turn_started, request})

    delta =
      Event.build(:llm_delta, [],
        request_id: "request-1",
        data: %{chunk_type: :content, delta: "Hi"}
      )

    {state, []} = State.update(state, {:jidoka, delta})
    assert state.streaming == "Hi"

    terminal = Event.build(:turn_finished, [delta], request_id: "request-1")
    {state, [{:finish_turn, ^request}]} = State.update(state, {:jidoka, terminal})
    assert state.finishing?

    {state, []} =
      State.update(state, {:turn_result, request, {:ok, :next_session, "Hi there"}})

    assert state.session == :next_session
    assert state.status == :idle
    refute state.finishing?
    assert state.messages |> List.last() |> Map.fetch!(:content) == "Hi there"
  end

  test "ignores a late result from an older request" do
    current = %{request_id: "current"}
    old = %{request_id: "old"}
    state = %{State.new(:session, {80, 24}) | request: current, status: :running}

    assert {^state, []} =
             State.update(state, {:turn_result, old, {:ok, :old_session, "old answer"}})
  end

  test "commits one completed result after a cancellation race" do
    request = %{request_id: "request-1"}

    state = %{
      State.new(:session, {80, 24})
      | request: request,
        status: :cancelling,
        messages: [%{role: :user, content: "hello"}]
    }

    {state, []} =
      State.update(state, {:turn_result, request, {:ok, :next_session, "completed"}})

    assert state.status == :idle
    assert state.request == nil
    assert Enum.count(state.messages, &(&1.role == :assistant)) == 1
    assert List.last(state.messages).content == "completed"

    assert {^state, []} =
             State.update(state, {:turn_result, request, {:ok, :next_session, "duplicate"}})
  end

  test "Ctrl-C exits while idle and cancels while running" do
    state = State.new(:session, {80, 24})
    assert {_state, [:exit]} = State.update(state, {:terminal, {:key, :ctrl_c}})

    request = %{request_id: "request-1"}
    {state, []} = State.update(state, {:turn_started, request})

    assert {state, [{:cancel_turn, ^request}]} =
             State.update(state, {:terminal, {:key, :ctrl_c}})

    assert state.status == :cancelling
  end

  test "edits the prompt and handles terminal control events" do
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:paste, "ab"}})
    {state, []} = State.update(state, {:terminal, {:key, :left}})
    {state, []} = State.update(state, {:terminal, {:key, :right}})
    {state, []} = State.update(state, {:terminal, {:key, :backspace}})
    assert state.editor.text == "a"

    {state, []} = State.update(state, {:terminal, {:resize, 100, 40}})
    assert state.size == {100, 40}
    assert {_state, [:exit]} = State.update(state, {:terminal, :eof})
  end

  test "does not submit an empty prompt or accept controls during a turn" do
    state = State.new(:session, {80, 24})
    assert {^state, []} = State.update(state, {:terminal, {:key, :enter}})

    request = %{request_id: "request-1"}
    {state, []} = State.update(state, {:turn_started, request})
    assert {^state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert {^state, []} = State.update(state, {:terminal, {:key, :escape}})
  end

  test "filters Jidoka events by active request" do
    delta =
      Event.build(:llm_delta, [],
        request_id: "other",
        data: %{chunk_type: :content, delta: "ignored"}
      )

    idle = State.new(:session, {80, 24})
    assert {^idle, []} = State.update(idle, {:jidoka, delta})

    request = %{request_id: "current"}
    running = %{idle | request: request, status: :running}
    assert {^running, []} = State.update(running, {:jidoka, delta})

    permissive = %{idle | request: :opaque, status: :running}
    {permissive, []} = State.update(permissive, {:jidoka, delta})
    assert permissive.streaming == "ignored"
  end

  test "normalizes all supported turn results" do
    base = %{State.new(:session, {80, 24}) | request: :request, streaming: "partial"}

    {state, []} = State.update(base, {:turn_result, {:ok, "answer"}})
    assert state.status == :idle
    assert List.last(state.messages).content == "answer"

    {state, []} =
      State.update(base, {:turn_result, {:hibernate, :new_session, :snapshot}})

    assert state.session == :new_session
    assert state.status == :interrupted
    assert state.error == "Agent paused for review."

    {state, []} = State.update(base, {:turn_result, {:hibernate, :snapshot}})
    assert state.session == :session
    assert state.status == :interrupted

    cancellation = Cancellation.new!(request_id: "request-1", cancelled_at_ms: 0)
    {state, []} = State.update(base, {:turn_result, {:cancelled, cancellation}})
    assert state.status == :idle
    assert state.request == nil

    {state, []} =
      State.update(base, {:turn_result, {:error, RuntimeError.exception("failed")}})

    assert state.error == "failed"

    {state, []} = State.update(base, {:turn_result, {:error, "plain failure"}})
    assert state.error == "plain failure"

    {state, []} = State.update(base, {:turn_result, {:error, {:bad, :reason}}})
    assert is_binary(state.error)
  end

  test "keeps an empty transcript and ignores unknown events" do
    state = %{State.new(:session, {80, 24}) | request: :request, dirty?: false}
    {state, []} = State.update(state, {:turn_result, {:ok, ""}})
    assert state.messages == []

    {state, []} = State.update(state, :render_scheduled)
    assert state.render_scheduled?
    {state, []} = State.update(state, :rendered)
    refute state.render_scheduled?
    refute state.dirty?
    assert {^state, []} = State.update(state, :unknown)
  end

  test "prepares a prompt before it enters the transcript" do
    state = State.new(:session, {80, 24}, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "Review @value.ex"}})

    assert {resolving, [{:prepare_prompt, "Review @value.ex"}]} =
             State.update(state, {:terminal, {:key, :enter}})

    assert resolving.status == :resolving
    assert resolving.messages == []
    assert resolving.editor.text == "Review @value.ex"

    context = %{"coding" => %{"files" => [%{"path" => "value.ex"}]}}

    assert {ready, [{:start_turn, "Review value.ex", ^context}]} =
             State.update(resolving, {:prompt_ready, "Review value.ex", context})

    assert ready.messages == [%{role: :user, content: "Review value.ex"}]
    assert ready.editor.text == ""
  end

  test "a prompt resolution error keeps text editable and starts no turn" do
    state = State.new(:session, {80, 24}, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "Review @missing"}})
    {state, [_effect]} = State.update(state, {:terminal, {:key, :enter}})
    {state, []} = State.update(state, {:prompt_error, "file is missing"})

    assert state.status == :error
    assert state.editor.text == "Review @missing"
    assert state.messages == []
  end

  test "stores only normalized coding review data from a completed turn" do
    digest = "sha256:" <> String.duplicate("a", 64)

    review = %{
      "kind" => "edit",
      "path" => "lib/value.ex",
      "action" => "edit",
      "operation_id" => "edit-1",
      "before_sha256" => digest,
      "after_sha256" => digest,
      "checkpoint" => %{"checkpoint_ref" => "checkpoint-1"},
      "diff" => %{"changed_before_lines" => 1, "changed_after_lines" => 1}
    }

    state = %{State.new(:session, {80, 24}) | request: :request}

    {state, []} =
      State.update(state, {:turn_result, {:ok, :next_session, "done", [review, %{"bad" => true}]}})

    assert state.session == :next_session
    assert state.status == :idle
    assert [%{"path" => "lib/value.ex", "status" => "changed"}] = state.coding_reviews

    {state, []} =
      State.update(state, {:coding_review, [%{"kind" => "mutation_state", "status" => "cancelled"}]})

    assert [%{"status" => "cancelled"}] = state.coding_reviews
  end
end
