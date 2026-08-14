defmodule Jido.Cli.Tui.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.State
  alias Jido.Cli.Runtime.Jidoka, as: Runtime
  alias Jidoka.Cancellation
  alias Jidoka.Event

  test "submits a prompt and commits a streamed result" do
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "hello"}})
    {state, [{:start_turn, "hello"}]} = State.update(state, {:terminal, {:key, :enter}})
    assert state.messages == [%{role: :user, content: "hello"}]

    request = %{request_id: "request-1"}
    {state, [{:await_turn, ^request}]} = State.update(state, {:turn_started, request})

    delta =
      Event.build(:llm_delta, [],
        request_id: "request-1",
        data: %{chunk_type: :content, delta: "Hi"}
      )

    {state, []} = State.update(state, {:jidoka, delta})
    assert state.streaming == "Hi"

    terminal = Event.build(:turn_finished, [delta], request_id: "request-1")
    {state, []} = State.update(state, {:jidoka, terminal})
    assert state.finishing?

    {state, []} =
      State.update(state, {:turn_result, request, {:ok, :next_session, "Hi there"}})

    assert state.session == :next_session
    assert state.status == :idle
    refute state.finishing?
    assert state.messages |> List.last() |> Map.fetch!(:content) == "Hi there"
  end

  test "commits a normalized runtime result for the active request" do
    session =
      struct!(Runtime.Session,
        data: :next_data,
        extension_host: :extension_host,
        runtime_opts: [operations: :operations],
        local_resources: :local_resources
      )

    request =
      struct!(Runtime.Request,
        request_id: "request-1",
        request: :opaque_request,
        session: session,
        runtime_opts: [request_id: "request-1"],
        extension_host: session.extension_host,
        local_resources: session.local_resources
      )

    result =
      struct!(Runtime.Result,
        request_id: request.request_id,
        status: :ok,
        session: session,
        runtime_opts: request.runtime_opts,
        extension_host: request.extension_host,
        local_resources: request.local_resources,
        handle: request,
        content: "normalized answer"
      )

    state = %{State.new(:old_session, {80, 24}) | request: request, status: :running}
    {state, []} = State.update(state, {:turn_result, request, result})

    assert state.session == session
    assert state.request == nil
    assert state.status == :idle
    assert List.last(state.messages).content == "normalized answer"
  end

  test "archives one explicit turn record with prompt, attachment, assistant, and outcome" do
    context = %{
      "coding" => %{
        "files" => [
          %{
            "path" => "lib/value.ex",
            "content" => "defmodule Value do\nend\n",
            "size" => 23,
            "sha256" => "sha256:value"
          }
        ]
      }
    }

    state = State.new(:session, {80, 24}, prepare_prompt: true)

    {state, [{:start_turn, "Review value.ex", ^context}]} =
      State.update(state, {:prompt_ready, "Review value.ex", context})

    request = %{request_id: "request-1"}
    {state, [{:await_turn, ^request}]} = State.update(state, {:turn_started, request})

    delta =
      Event.build(:llm_delta, [],
        request_id: "request-1",
        seq: 0,
        data: %{chunk_type: :content, delta: "partial"}
      )

    {state, []} = State.update(state, {:jidoka, delta})

    {state, []} =
      State.update(state, {:turn_result, request, {:ok, :next_session, "final answer"}})

    assert state.active_turn == nil
    assert [turn] = state.turns
    assert turn.request_id == "request-1"
    assert turn.prompt == "Review value.ex"

    assert turn.attachments == [
             %{"path" => "lib/value.ex", "size" => 23, "sha256" => "sha256:value"}
           ]

    assert turn.assistant == "final answer"
    assert turn.outcome.status == :completed
  end

  test "keeps one wrapped turn through repeated approval and denial pauses" do
    request = %{request_id: "request-1"}
    first_review = review("review-1", "write_file", %{"path" => "\e[31mlib/a.ex\e[0m"})
    second_review = review("review-2", "shell", %{"command" => "mix test\e[2J"})

    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "change it"}})
    {state, [{:start_turn, "change it"}]} = State.update(state, {:terminal, {:key, :enter}})
    {state, [{:await_turn, ^request}]} = State.update(state, {:turn_started, request})

    first_pause = runtime_result(:pending_review, request, :wrapped_session_1, pending_reviews: [first_review])
    {state, []} = State.update(state, {:turn_result, request, first_pause})

    assert state.status == :review
    assert state.session == :wrapped_session_1
    assert state.turns == []
    assert state.active_turn.reviews |> hd() |> Map.fetch!(:arguments_summary) == "%{\"path\" => \"lib/a.ex\"}"

    assert {state, [{:respond_review, :approve, ^first_pause, ^first_review}]} =
             State.update(state, {:terminal, {:text, "a"}})

    assert state.status == :responding_review
    assert {^state, []} = State.update(state, {:terminal, {:text, "d"}})

    second_pause = runtime_result(:pending_review, request, :wrapped_session_2, pending_reviews: [second_review])
    {state, []} = State.update(state, {:turn_result, second_pause})
    assert state.session == :wrapped_session_2
    assert state.status == :review

    assert {state, [{:respond_review, :deny, ^second_pause, ^second_review}]} =
             State.update(state, {:terminal, {:text, "d"}})

    denied =
      runtime_result(:error, request, :wrapped_session_3,
        error: :review_denied,
        approval: :denied
      )

    {state, []} = State.update(state, {:turn_result, denied})

    assert state.session == :wrapped_session_3
    assert state.active_turn == nil
    assert [turn] = state.turns
    assert Enum.map(turn.reviews, & &1.decision) == [:approve, :deny]
    assert Enum.map(turn.reviews, & &1.status) == [:approved, :denied]
    assert turn.outcome.status == :failed
  end

  test "records an expired approval without losing its decision" do
    request = %{request_id: "request-1"}

    pending =
      runtime_result(:pending_review, request, :wrapped_session,
        pending_reviews: [review("review-1", "write_file", %{})]
      )

    state = State.new(:session, {80, 24})
    {state, [{:await_turn, ^request}]} = State.update(state, {:turn_started, request})
    {state, []} = State.update(state, {:turn_result, request, pending})
    {state, [_effect]} = State.update(state, {:terminal, {:text, "a"}})

    expired = runtime_result(:error, request, :wrapped_session, error: :review_expired)
    {state, []} = State.update(state, {:turn_result, expired})

    assert [turn] = state.turns
    assert [%{decision: :approve, status: :expired, error: error}] = turn.reviews
    assert error =~ "expired"
  end

  test "queues the current prompt until the runtime is ready" do
    state = State.new(nil, {80, 24}, runtime_status: :starting, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "Review @value.ex"}})

    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert state.submit_when_ready?
    assert state.editor.text == "Review @value.ex"
    assert state.messages == []

    {state, []} = State.update(state, {:terminal, {:text, " now"}})

    assert {ready, [{:prepare_prompt, "Review @value.ex now"}]} =
             State.update(state, {:runtime_ready, :session, [%{"path" => "AGENTS.md"}]})

    assert ready.session == :session
    assert ready.runtime_status == :ready
    assert ready.status == :resolving
    refute ready.submit_when_ready?
    assert ready.project_instructions == [%{"path" => "AGENTS.md"}]
  end

  test "keeps unsubmitted text and reports a runtime startup failure" do
    state = State.new(nil, {80, 24}, runtime_status: :starting, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "draft"}})

    {ready, []} = State.update(state, {:runtime_ready, :session, []})
    assert ready.runtime_status == :ready
    assert ready.status == :idle
    assert ready.editor.text == "draft"

    {failed, []} = State.update(state, {:runtime_failed, :boot_failed})
    assert failed.runtime_status == :failed
    assert failed.startup_error == :boot_failed
    assert failed.error =~ "boot_failed"
    assert {^failed, []} = State.update(failed, {:terminal, {:key, :enter}})
    assert {_failed, [:exit]} = State.update(failed, {:terminal, {:key, :escape}})
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
    {state, [{:await_turn, ^request}]} = State.update(state, {:turn_started, request})

    assert {state, [{:cancel_turn, ^request}]} =
             State.update(state, {:terminal, {:key, :ctrl_c}})

    assert state.status == :cancelling
    assert {^state, []} = State.update(state, {:terminal, {:key, :ctrl_c}})
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

  test "keeps multiline drafts, bounded history, and history drafts" do
    state = State.new(:session, {80, 24}, history_limit: 2)

    {state, []} = State.update(state, {:terminal, {:text, "one"}})
    {state, []} = State.update(state, {:terminal, {:key, :newline}})
    {state, []} = State.update(state, {:terminal, {:text, "line"}})
    assert state.editor.text == "one\nline"

    {state, [{:start_turn, "one\nline"}]} = State.update(state, {:terminal, {:key, :enter}})
    {state, []} = State.update(state, {:turn_result, {:ok, "done"}})

    state =
      Enum.reduce(["two", "three"], state, fn prompt, state ->
        {state, []} = State.update(state, {:terminal, {:text, prompt}})
        {state, [{:start_turn, ^prompt}]} = State.update(state, {:terminal, {:key, :enter}})
        {state, []} = State.update(state, {:turn_result, {:ok, "done"}})
        state
      end)

    assert state.history == ["two", "three"]

    {state, []} = State.update(state, {:terminal, {:text, "draft"}})
    {state, []} = State.update(state, {:terminal, {:key, :up}})
    assert state.editor.text == "three"
    {state, []} = State.update(state, {:terminal, {:key, :up}})
    assert state.editor.text == "two"
    {state, []} = State.update(state, {:terminal, {:key, :down}})
    {state, []} = State.update(state, {:terminal, {:key, :down}})
    assert state.editor.text == "draft"
  end

  test "retains a draft after prompt preparation fails" do
    state = State.new(:session, {80, 24}, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "Review @missing.ex"}})
    {state, [{:prepare_prompt, "Review @missing.ex"}]} = State.update(state, {:terminal, {:key, :enter}})
    {state, []} = State.update(state, {:prompt_error, :missing})

    assert state.editor.text == "Review @missing.ex"
    assert state.pending_prompt == nil
  end

  test "retains the next draft while a turn completes" do
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "first"}})
    {state, [{:start_turn, "first"}]} = State.update(state, {:terminal, {:key, :enter}})
    {state, []} = State.update(state, {:terminal, {:text, "next\e[2J draft"}})
    {state, []} = State.update(state, {:turn_result, {:ok, "answer"}})

    assert state.editor.text == "next draft"
  end

  test "scrolls by pages, follows new prompts, and bounds archived turns" do
    state = State.new(:session, {80, 8}, turn_limit: 2)
    {state, []} = State.update(state, {:terminal, {:key, :page_up}})
    assert state.scroll_offset == 4
    {state, []} = State.update(state, {:terminal, {:key, :page_down}})
    assert state.scroll_offset == 0

    state = %{state | scroll_offset: 20}

    state =
      Enum.reduce(["one", "two", "three"], state, fn prompt, state ->
        {state, []} = State.update(state, {:terminal, {:text, prompt}})
        {state, [{:start_turn, ^prompt}]} = State.update(state, {:terminal, {:key, :enter}})
        assert state.scroll_offset == 0
        {state, []} = State.update(state, {:turn_result, {:ok, "answer #{prompt}"}})
        state
      end)

    assert Enum.map(state.turns, & &1.prompt) == ["two", "three"]
    assert length(state.messages) == 4
  end

  test "does not submit an empty prompt or accept controls during a turn" do
    state = State.new(:session, {80, 24})
    assert {^state, []} = State.update(state, {:terminal, {:key, :enter}})

    request = %{request_id: "request-1"}

    pre_request = %{state | editor: Jido.Cli.Tui.Editor.from_text("second"), status: :running}
    assert {^pre_request, []} = State.update(pre_request, {:terminal, {:key, :enter}})

    {state, [{:await_turn, ^request}]} = State.update(state, {:turn_started, request})
    assert {^state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert {^state, []} = State.update(state, {:terminal, {:key, :escape}})
  end

  test "accepts only checked events for the active request" do
    other_delta =
      Event.build(:llm_delta, [],
        request_id: "other",
        data: %{chunk_type: :content, delta: "ignored"}
      )

    idle = State.new(:session, {80, 24})
    assert {^idle, []} = State.update(idle, {:jidoka, other_delta})

    request = %{request_id: "current"}
    {running, [{:await_turn, ^request}]} = State.update(idle, {:turn_started, request})
    assert {^running, []} = State.update(running, {:jidoka, other_delta})

    current_delta =
      Event.build(:llm_delta, [],
        request_id: "current",
        data: %{chunk_type: :content, delta: "accepted"}
      )

    {running, []} = State.update(running, {:jidoka, current_delta})
    assert running.streaming == "accepted"

    {opaque, [{:await_turn, :opaque}]} = State.update(idle, {:turn_started, :opaque})
    assert {^opaque, []} = State.update(opaque, {:jidoka, other_delta})
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

    {state, []} = State.update(base, {:turn_result, {:error, :request_expired}})
    assert state.error =~ "internal request error"
    assert state.error =~ "does not mean that the API key is invalid"
    assert state.error =~ "Try the prompt again"

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

  defp runtime_result(status, request, session, attrs) do
    struct!(
      Runtime.Result,
      Keyword.merge(
        [
          request_id: request.request_id,
          status: status,
          session: session,
          runtime_opts: [],
          extension_host: :extension_host,
          local_resources: :local_resources,
          handle: request
        ],
        attrs
      )
    )
  end

  defp review(id, operation, arguments) do
    %{
      interrupt_id: id,
      operation: operation,
      arguments: arguments,
      reason: :manual,
      created_at_ms: 0,
      expires_at_ms: 30_000
    }
  end
end
