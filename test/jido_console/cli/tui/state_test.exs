defmodule Jido.Console.Tui.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{State, Turn}
  alias Jido.Console.Session.Event, as: SessionEvent
  alias Jido.Console.Session.Request, as: SessionRequest

  test "submits a prompt and commits canonical session output" do
    state = %{State.new(:session, {80, 24}) | semantic_session_id: "session"}
    {state, []} = State.update(state, {:terminal, {:text, "hello"}})
    {state, [{:start_turn, "hello"}]} = State.update(state, {:terminal, {:key, :enter}})
    assert state.messages == [%{role: :user, content: "hello"}]

    request = session_request("request-1")
    {state, []} = State.update(state, {:turn_started, request})

    state = apply_semantic(state, "model_delta", %{text: "Hi"})
    assert State.active_turn(state).assistant == "Hi"

    state = apply_semantic(state, "run_completed", %{content: "Hi there"})

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

    review_state = %{state | activity: {:review, request, turn, %{}, :awaiting}}

    for input <- [
          {:terminal, {:paste, "ignored"}},
          {:terminal, {:key, :newline}}
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

    state = %{state | semantic_session_id: "session"}
    state = apply_semantic(state, "model_delta", %{text: "partial"})
    state = apply_semantic(state, "run_completed", %{content: "final answer"})

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

    state = apply_semantic(state, "run_completed", %{content: "done"})

    state =
      Enum.reduce(["two", "three"], state, fn prompt, state ->
        {state, []} = State.update(state, {:terminal, {:text, prompt}})
        {state, [{:start_turn, ^prompt}]} = State.update(state, {:terminal, {:key, :enter}})

        state = apply_semantic(state, "run_completed", %{content: "done"})

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

    state = apply_semantic(state, "run_completed", %{content: "answer"})

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

        state = apply_semantic(state, "run_completed", %{content: "answer #{prompt}"})

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

  test "normalizes local client effect errors" do
    request = session_request("request-1")
    base = active_state(State.new(:session, {80, 24}), request, "partial")

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

  test "keeps an empty transcript and ignores unknown local events" do
    request = session_request("request-1")
    state = %{active_state(State.new(:session, {80, 24}), request) | dirty?: false}

    state = apply_semantic(state, "run_completed", %{content: ""})

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

  test "keeps canonical coding review updates" do
    projected = %{"kind" => "mutation_state", "status" => "cancelled"}
    state = State.new(:session, {80, 24})
    {state, []} = State.update(state, {:coding_review, [projected]})
    assert [%{"kind" => "mutation_state", "status" => "cancelled"}] = state.coding_reviews

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

  defp apply_semantic(state, type, fields) do
    session_id = state.semantic_session_id || "session"
    sequence = state.semantic_sequence + 1

    attrs =
      Map.merge(
        %{
          type: type,
          id: "event-#{sequence}",
          session_id: session_id,
          sequence: sequence,
          durability: "process",
          sensitivity: "public",
          origin: %{kind: "session", actor_id: session_id},
          trust: %{evidence: "test", policy: "session-owner"},
          identities: [
            %{"kind" => "session", "id" => session_id, "session_id" => session_id},
            %{"kind" => "jidoka_request", "id" => "request-1", "session_id" => session_id}
          ],
          run_id: "run-1"
        },
        fields
      )

    attrs =
      if type in ["run_completed", "run_failed", "session_failed"],
        do: Map.put(attrs, :outcome_id, "outcome-1"),
        else: attrs

    {:ok, event} = SessionEvent.classify(attrs)
    {:ok, state} = State.apply_session_event(%{state | semantic_session_id: session_id}, event)
    state
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
