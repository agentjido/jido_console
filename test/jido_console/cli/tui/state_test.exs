defmodule Jido.Console.Tui.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{State, Turn}
  alias Jido.Console.Runtime.Jidoka, as: Runtime
  alias Jido.Console.Runtime.Result
  alias Jido.Console.Session.Event, as: SessionEvent
  alias Jido.Console.Session.Request, as: SessionRequest
  alias Jidoka.Cancellation
  alias Jidoka.Event

  test "submits a prompt and commits a streamed result" do
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "hello"}})
    {state, [{:start_turn, "hello"}]} = State.update(state, {:terminal, {:key, :enter}})
    assert state.messages == [%{role: :user, content: "hello"}]

    request = session_request("request-1")
    {state, []} = State.update(state, {:turn_started, request})

    delta =
      Event.build(:llm_delta, [],
        request_id: "request-1",
        data: %{chunk_type: :content, delta: "Hi"}
      )

    {state, []} = State.update(state, {:jidoka, delta})
    assert State.active_turn(state).assistant == "Hi"

    terminal = Event.build(:turn_finished, [delta], request_id: "request-1")
    {state, []} = State.update(state, {:jidoka, terminal})
    assert {:active, ^request, %Turn{}, :finishing} = state.activity

    {state, []} =
      State.update(
        state,
        {:turn_result, request, runtime_result(:ok, request, :next_session, content: "Hi there")}
      )

    assert state.session == :next_session
    assert state.activity == :idle
    assert state.messages |> List.last() |> Map.fetch!(:content) == "Hi there"
  end

  test "handles inert activity input and incomplete restored transcripts" do
    state = State.new(:session, {80, 24}, catalog_entries: [], history_limit: 0, turn_limit: 0)
    assert state.history_limit == 100
    assert state.turn_limit == 100
    assert {^state, []} = State.update(state, {:terminal, {:key, :up}})
    assert {^state, []} = State.update(state, {:terminal, {:key, :down}})
    assert {^state, []} = State.update(state, {:turn_result, :invalid})

    preparing = %{state | activity: {:preparing, {:prompt, "prompt"}}}

    for input <- [
          {:terminal, {:text, "ignored"}},
          {:terminal, {:paste, "ignored"}},
          {:terminal, {:key, :newline}},
          {:terminal, {:key, :left}}
        ] do
      assert {^preparing, []} = State.update(preparing, input)
    end

    previous = state.selection
    selecting = %{state | activity: {:preparing, {:selection, previous}}, selection: %{model: "new"}}
    {failed, []} = State.update(selecting, {:prompt_error, :selection_failed})
    assert failed.selection == previous
    assert {:failed, :selection, :selection_failed, _message} = failed.activity

    request = session_request("review")
    turn = Turn.new(1, "prompt")

    pending =
      Result.pending_review("review", :session, :handle, [%{id: "review"}])
      |> put_in([Access.key!(:outcome), Access.key!(:reviews)], [])

    review_state = %{state | activity: {:review, request, turn, pending, :awaiting}}

    for input <- [
          {:terminal, {:paste, "ignored"}},
          {:terminal, {:key, :newline}},
          {:terminal, {:text, "a"}}
        ] do
      assert {^review_state, []} = State.update(review_state, input)
    end

    {unchanged, []} = State.update(state, {:coding_review, [%{path: "lib/value.ex"}]})
    assert unchanged.activity == :idle

    snapshot = %{
      "payload" => %{
        "state" => %{
          "transcript" => [
            %{"type" => "unknown", "payload" => %{}},
            %{"type" => "run_started", "payload" => %{"prompt" => "hello", "request_id" => "one"}},
            %{"type" => "model_delta", "payload" => %{"text" => "answer"}},
            %{"type" => "run_completed", "payload" => %{}},
            %{"type" => "run_started", "payload" => %{"prompt" => "again", "request_id" => "two"}}
          ]
        }
      }
    }

    restored = State.restore_snapshot(state, snapshot)
    assert {:starting, {:turn, %Turn{prompt: "again"}}} = restored.activity
    assert Enum.map(restored.messages, & &1.content) == ["hello", "answer", "again"]
    assert [%Turn{status: :finished}] = restored.turns
  end

  test "commits a normalized runtime result for the active request" do
    session =
      struct!(Runtime.Session,
        data: :next_data,
        extension_host: :extension_host,
        runtime_opts: [operations: :operations],
        local_resources: :local_resources
      )

    runtime_request =
      struct!(Runtime.Request,
        request_id: "request-1",
        request: :opaque_request,
        session: session,
        runtime_opts: [request_id: "request-1"]
      )

    request = session_request("request-1")
    result = Result.ok(runtime_request.request_id, session, runtime_request, "normalized answer")

    state = active_state(State.new(:old_session, {80, 24}), request)
    {state, []} = State.update(state, {:turn_result, request, result})

    assert state.session == session
    assert State.active_request(state) == nil
    assert state.activity == :idle
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
    {state, []} = State.update(state, {:terminal, {:text, "Review @value.ex"}})
    {state, [{:prepare_prompt, "Review @value.ex"}]} = State.update(state, {:terminal, {:key, :enter}})

    {state, [{:start_turn, "Review value.ex", ^context}]} =
      State.update(state, {:prompt_ready, "Review value.ex", context})

    request = session_request("request-1")
    {state, []} = State.update(state, {:turn_started, request})

    delta =
      Event.build(:llm_delta, [],
        request_id: "request-1",
        seq: 0,
        data: %{chunk_type: :content, delta: "partial"}
      )

    {state, []} = State.update(state, {:jidoka, delta})

    {state, []} =
      State.update(
        state,
        {:turn_result, request, runtime_result(:ok, request, :next_session, content: "final answer")}
      )

    assert State.active_turn(state) == nil
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
    request = session_request("request-1")
    first_review = review("review-1", "write_file", %{"path" => "\e[31mlib/a.ex\e[0m"})
    second_review = review("review-2", "shell", %{"command" => "mix test\e[2J"})

    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "change it"}})
    {state, [{:start_turn, "change it"}]} = State.update(state, {:terminal, {:key, :enter}})
    {state, []} = State.update(state, {:turn_started, request})

    first_pause = runtime_result(:pending_review, request, :wrapped_session_1, pending_reviews: [first_review])
    {state, []} = State.update(state, {:turn_result, request, first_pause})

    assert {:review, ^request, %Turn{}, ^first_pause, :awaiting} = state.activity
    assert state.session == :wrapped_session_1
    assert state.turns == []
    assert State.active_turn(state).reviews |> hd() |> Map.fetch!(:arguments_summary) == "%{\"path\" => \"lib/a.ex\"}"

    assert {state, [{:respond_review, :approve, ^request, ^first_pause, ^first_review}]} =
             State.update(state, {:terminal, {:text, "a"}})

    assert {:review, ^request, %Turn{}, ^first_pause, {:responding, :approve}} = state.activity
    assert {^state, []} = State.update(state, {:terminal, {:text, "d"}})

    second_pause = runtime_result(:pending_review, request, :wrapped_session_2, pending_reviews: [second_review])
    {state, []} = State.update(state, {:turn_result, second_pause})
    assert state.session == :wrapped_session_2
    assert {:review, ^request, %Turn{}, ^second_pause, :awaiting} = state.activity

    assert {state, [{:respond_review, :deny, ^request, ^second_pause, ^second_review}]} =
             State.update(state, {:terminal, {:text, "d"}})

    denied =
      runtime_result(:error, request, :wrapped_session_3,
        error: :review_denied,
        approval: :denied
      )

    {state, []} = State.update(state, {:turn_result, denied})

    assert state.session == :wrapped_session_3
    assert State.active_turn(state) == nil
    assert [turn] = state.turns
    assert Enum.map(turn.reviews, & &1.decision) == [:approve, :deny]
    assert Enum.map(turn.reviews, & &1.status) == [:approved, :denied]
    assert turn.outcome.status == :failed
  end

  test "records an expired approval without losing its decision" do
    request = session_request("request-1")

    pending =
      runtime_result(:pending_review, request, :wrapped_session,
        pending_reviews: [review("review-1", "write_file", %{})]
      )

    state = State.new(:session, {80, 24}) |> starting_state()
    {state, []} = State.update(state, {:turn_started, request})
    {state, []} = State.update(state, {:turn_result, request, pending})
    {state, [_effect]} = State.update(state, {:terminal, {:text, "a"}})

    expired = runtime_result(:error, request, :wrapped_session, error: :review_expired)
    {state, []} = State.update(state, {:turn_result, expired})

    assert [turn] = state.turns
    assert [%{decision: :approve, status: :expired, error: error}] = turn.reviews
    assert error =~ "expired"
  end

  test "queues the current prompt until the runtime is ready" do
    state = State.new(nil, {80, 24}, activity: {:starting, {:runtime, :empty}}, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "Review @value.ex"}})

    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert state.activity == {:starting, {:runtime, :submit_when_ready}}
    assert state.editor.text == "Review @value.ex"
    assert state.messages == []

    {state, []} = State.update(state, {:terminal, {:text, " now"}})

    assert {ready, [{:prepare_prompt, "Review @value.ex now"}]} =
             State.update(state, {:runtime_ready, :session, [%{"path" => "AGENTS.md"}]})

    assert ready.session == :session
    assert ready.activity == {:preparing, {:prompt, "Review @value.ex now"}}
    assert ready.project_instructions == [%{"path" => "AGENTS.md"}]
  end

  test "keeps unsubmitted text and reports a runtime startup failure" do
    state = State.new(nil, {80, 24}, activity: {:starting, {:runtime, :empty}}, prepare_prompt: true)
    {state, []} = State.update(state, {:terminal, {:text, "draft"}})

    {ready, []} = State.update(state, {:runtime_ready, :session, []})
    assert ready.activity == :idle
    assert ready.editor.text == "draft"

    {failed, []} = State.update(state, {:runtime_failed, :boot_failed})
    assert {:failed, :startup, :boot_failed, error} = failed.activity
    assert error =~ "boot_failed"
    assert {^failed, []} = State.update(failed, {:terminal, {:key, :enter}})
    assert {_failed, [:exit]} = State.update(failed, {:terminal, {:key, :escape}})
  end

  test "runtime readiness does not replace restored active work" do
    request = session_request("request-1")
    state = active_state(State.new(nil, {80, 24}), request, "restored")

    {ready, []} = State.update(state, {:runtime_ready, :session, [%{"path" => "AGENTS.md"}]})

    assert {:active, ^request, %Turn{assistant: "restored"}, :streaming} = ready.activity
    assert ready.session == :session
    assert ready.project_instructions == [%{"path" => "AGENTS.md"}]
  end

  test "ignores a late result from an older request" do
    current = session_request("current")
    old = session_request("old")
    state = active_state(State.new(:session, {80, 24}), current)

    assert {^state, []} =
             State.update(
               state,
               {:turn_result, old, runtime_result(:ok, old, :old_session, content: "old answer")}
             )
  end

  test "commits one completed result after a cancellation race" do
    request = session_request("request-1")

    state = active_state(State.new(:session, {80, 24}), request)
    {state, [{:cancel_turn, ^request}]} = State.update(state, {:terminal, {:key, :ctrl_c}})
    state = %{state | messages: [%{role: :user, content: "hello"}]}

    {state, []} =
      State.update(
        state,
        {:turn_result, request, runtime_result(:ok, request, :next_session, content: "completed")}
      )

    assert state.activity == :idle
    assert State.active_request(state) == nil
    assert Enum.count(state.messages, &(&1.role == :assistant)) == 1
    assert List.last(state.messages).content == "completed"

    assert {^state, []} =
             State.update(
               state,
               {:turn_result, request, runtime_result(:ok, request, :next_session, content: "duplicate")}
             )
  end

  test "Ctrl-C exits while idle and cancels while running" do
    state = State.new(:session, {80, 24})
    assert {_state, [:exit]} = State.update(state, {:terminal, {:key, :ctrl_c}})

    request = session_request("request-1")
    state = starting_state(state)
    {state, []} = State.update(state, {:turn_started, request})

    assert {state, [{:cancel_turn, ^request}]} =
             State.update(state, {:terminal, {:key, :ctrl_c}})

    assert {:cancelling, %Turn{}, {:request, ^request}} = state.activity
    assert {^state, []} = State.update(state, {:terminal, {:key, :ctrl_c}})
  end

  test "cancels a turn that has not received its request yet" do
    request = session_request("request-1")
    state = State.new(:session, {80, 24}) |> starting_state("queued")

    {state, []} = State.update(state, {:terminal, {:key, :ctrl_c}})
    assert {:cancelling, %Turn{prompt: "queued"}, :before_start} = state.activity

    assert {state, [{:cancel_turn, ^request}]} = State.update(state, {:turn_started, request})
    assert {:cancelling, %Turn{}, {:request, ^request}} = state.activity
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

    {state, []} =
      State.update(state, {:turn_result, runtime_result(:ok, :request, state.session, content: "done")})

    state =
      Enum.reduce(["two", "three"], state, fn prompt, state ->
        {state, []} = State.update(state, {:terminal, {:text, prompt}})
        {state, [{:start_turn, ^prompt}]} = State.update(state, {:terminal, {:key, :enter}})

        {state, []} =
          State.update(state, {:turn_result, runtime_result(:ok, :request, state.session, content: "done")})

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
    assert {:failed, :preparation, :missing, _message} = state.activity
  end

  test "retains the next draft while a turn completes" do
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:terminal, {:text, "first"}})
    {state, [{:start_turn, "first"}]} = State.update(state, {:terminal, {:key, :enter}})
    {state, []} = State.update(state, {:terminal, {:text, "next\e[2J draft"}})

    {state, []} =
      State.update(state, {:turn_result, runtime_result(:ok, :request, state.session, content: "answer")})

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

        {state, []} =
          State.update(
            state,
            {:turn_result, runtime_result(:ok, :request, state.session, content: "answer #{prompt}")}
          )

        state
      end)

    assert Enum.map(state.turns, & &1.prompt) == ["two", "three"]
    assert length(state.messages) == 4
  end

  test "does not submit an empty prompt or accept controls during a turn" do
    state = State.new(:session, {80, 24})
    assert {^state, []} = State.update(state, {:terminal, {:key, :enter}})

    request = session_request("request-1")

    pre_request = %{
      state
      | editor: Jido.Console.Tui.Editor.from_text("second"),
        activity: {:starting, {:turn, Turn.new(0, "first")}}
    }

    assert {^pre_request, []} = State.update(pre_request, {:terminal, {:key, :enter}})

    state = starting_state(state)
    {state, []} = State.update(state, {:turn_started, request})
    assert {^state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert {^state, []} = State.update(state, {:terminal, {:key, :escape}})
  end

  test "keeps a permission event active when it arrives before the request handle" do
    state =
      State.new(:session, {80, 24})
      |> starting_state("review")
      |> Map.put(:semantic_session_id, "session")

    {:ok, permission} =
      SessionEvent.classify(%{
        type: "permission_requested",
        session_id: "session",
        sequence: 1,
        durability: "process",
        sensitivity: "redacted",
        origin: %{kind: "jidoka", actor_id: "runtime"},
        trust: %{evidence: "projected", policy: "session-owner"},
        identities: [
          %{"kind" => "jidoka_request", "id" => "request-1", "session_id" => "session"}
        ],
        approval_id: "review-1",
        principal: "user",
        scope: "write_file"
      })

    assert {:ok, state} = State.apply_session_event(state, permission)
    request = session_request("request-1")
    {state, []} = State.update(state, {:turn_started, request})

    assert {:review, ^request, %Turn{}, %{}, :awaiting} = state.activity

    assert {state, [{:respond_review, :approve, ^request, %{}, review}]} =
             State.update(state, {:terminal, {:text, "a"}})

    assert review.id == "review-1"
    assert {:review, ^request, %Turn{}, %{}, {:responding, :approve}} = state.activity
  end

  test "accepts only checked events for the active request" do
    other_delta =
      Event.build(:llm_delta, [],
        request_id: "other",
        data: %{chunk_type: :content, delta: "ignored"}
      )

    idle = State.new(:session, {80, 24})
    assert {^idle, []} = State.update(idle, {:jidoka, other_delta})

    request = session_request("current")
    idle_starting = starting_state(idle)
    {running, []} = State.update(idle_starting, {:turn_started, request})
    assert {^running, []} = State.update(running, {:jidoka, other_delta})

    current_delta =
      Event.build(:llm_delta, [],
        request_id: "current",
        data: %{chunk_type: :content, delta: "accepted"}
      )

    {running, []} = State.update(running, {:jidoka, current_delta})
    assert State.active_turn(running).assistant == "accepted"

    assert {^idle, []} = State.update(idle, {:turn_started, :opaque})
  end

  test "normalizes all supported turn results" do
    request = session_request("request-1")
    base = active_state(State.new(:session, {80, 24}), request, "partial")

    {state, []} =
      State.update(base, {:turn_result, runtime_result(:ok, request, :session, content: "answer")})

    assert state.activity == :idle
    assert List.last(state.messages).content == "answer"

    {state, []} =
      State.update(
        base,
        {:turn_result, runtime_result(:hibernated, request, :new_session, snapshot: :snapshot)}
      )

    assert state.session == :new_session
    assert {:failed, :hibernated, _reason, "Agent paused."} = state.activity

    {state, []} =
      State.update(
        base,
        {:turn_result, runtime_result(:hibernated, request, :session, snapshot: :snapshot)}
      )

    assert state.session == :session
    assert {:failed, :hibernated, _reason, "Agent paused."} = state.activity

    cancellation = Cancellation.new!(request_id: "request-1", cancelled_at_ms: 0)

    {state, []} =
      State.update(
        base,
        {:turn_result, runtime_result(:cancelled, request, :session, cancellation: cancellation)}
      )

    assert state.activity == :idle
    assert State.active_request(state) == nil

    {state, []} =
      State.update(base, {:turn_result, {:error, RuntimeError.exception("failed")}})

    assert {:failed, :turn, _reason, "failed"} = state.activity
    assert State.active_request(state) == nil
    assert State.active_turn(state) == nil

    {state, []} = State.update(base, {:turn_result, {:error, "plain failure"}})
    assert {:failed, :turn, _reason, "plain failure"} = state.activity

    {state, []} = State.update(base, {:turn_result, {:error, :request_expired}})
    assert {:failed, :turn, _reason, error} = state.activity
    assert error =~ "internal request error"
    assert error =~ "does not mean that the API key is invalid"
    assert error =~ "Try the prompt again"

    {state, []} = State.update(base, {:turn_result, {:error, {:bad, :reason}}})
    assert {:failed, :turn, _reason, error} = state.activity
    assert is_binary(error)
  end

  test "keeps an empty transcript and ignores unknown events" do
    request = session_request("request-1")
    state = %{active_state(State.new(:session, {80, 24}), request) | dirty?: false}

    {state, []} =
      State.update(state, {:turn_result, runtime_result(:ok, request, :session, content: "")})

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

    assert resolving.activity == {:preparing, {:prompt, "Review @value.ex"}}
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

    assert {:failed, :preparation, "file is missing", "file is missing"} = state.activity
    assert state.editor.text == "Review @missing"
    assert state.messages == []
  end

  test "keeps runtime review projections and validates raw review events" do
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

    request = session_request("request-1")
    state = active_state(State.new(:session, {80, 24}), request)

    {state, []} =
      State.update(
        state,
        {:turn_result,
         runtime_result(:ok, request, :next_session,
           content: "done",
           coding_review_candidates: [review, %{"bad" => true}]
         )}
      )

    assert state.session == :next_session
    assert state.activity == :idle
    assert [projected] = state.coding_reviews
    assert projected["path"] == "lib/value.ex"
    assert projected["status"] == "changed"
    assert projected["before_sha256"] == "sha256:aaaaaaaaaaaa"
    assert projected["after_sha256"] == "sha256:aaaaaaaaaaaa"

    {state, []} = State.update(state, {:coding_review, [projected]})
    assert state.coding_reviews == []

    {state, []} =
      State.update(state, {:coding_review, [%{"kind" => "mutation_state", "status" => "cancelled"}]})

    assert [%{"status" => "cancelled"}] = state.coding_reviews
  end

  test "stores semantic work only in the tagged activity" do
    state = State.new(:session, {80, 24})

    for removed <- [
          :active_turn,
          :error,
          :finishing?,
          :pending_prompt,
          :pending_review,
          :request,
          :runtime_status,
          :startup_error,
          :status,
          :streaming,
          :submit_when_ready?
        ] do
      refute Map.has_key?(state, removed)
    end

    assert state.activity == :idle
  end

  defp starting_state(state, prompt \\ "") do
    %{state | activity: {:starting, {:turn, Turn.new(state.next_turn_id, prompt)}}}
  end

  defp active_state(state, request, assistant \\ "") do
    turn = Turn.new(state.next_turn_id, "") |> Turn.put_request(request) |> Map.put(:assistant, assistant)
    %{state | activity: {:active, request, turn, :streaming}}
  end

  defp runtime_result(status, request, session, attrs) do
    request_id = if is_map(request), do: Map.get(request, :request_id, "request"), else: "request"

    case status do
      :ok ->
        Result.ok(request_id, session, request, Keyword.fetch!(attrs, :content),
          coding_review_candidates: Keyword.get(attrs, :coding_review_candidates, []),
          approval: Keyword.get(attrs, :approval)
        )

      :pending_review ->
        Result.pending_review(
          request_id,
          session,
          request,
          Keyword.fetch!(attrs, :pending_reviews),
          snapshot: Keyword.get(attrs, :snapshot),
          approval: Keyword.get(attrs, :approval)
        )

      :hibernated ->
        Result.hibernated(request_id, session, request,
          snapshot: Keyword.get(attrs, :snapshot),
          reason: Keyword.get(attrs, :reason),
          approval: Keyword.get(attrs, :approval)
        )

      :cancelled ->
        Result.cancelled(request_id, session, request, Keyword.fetch!(attrs, :cancellation),
          approval: Keyword.get(attrs, :approval)
        )

      :error ->
        Result.error(request_id, session, request, Keyword.fetch!(attrs, :error),
          approval: Keyword.get(attrs, :approval)
        )
    end
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

  defp session_request(request_id) do
    %SessionRequest{
      id: "session-#{request_id}",
      request_id: request_id,
      run_id: "run-#{request_id}",
      session_id: "session"
    }
  end
end
