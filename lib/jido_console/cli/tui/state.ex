defmodule Jido.Console.Tui.State do
  @moduledoc "Pure state transitions for the Jido TUI."

  alias Jido.Console.Tui.{Editor, EventProjection, Selection, Turn}
  alias Jido.Console.Runtime.Jidoka.Result, as: RuntimeResult

  @default_history_limit 100
  @default_turn_limit 100
  @review_limit 100
  @max_scroll_offset 1_000_000

  @enforce_keys [:session, :size]
  defstruct session: nil,
            session_client: nil,
            size: nil,
            editor: %Editor{},
            history: [],
            history_index: nil,
            history_draft: nil,
            history_limit: @default_history_limit,
            pending_prompt: nil,
            scroll_offset: 0,
            turn_limit: @default_turn_limit,
            messages: [],
            streaming: "",
            runtime_status: :ready,
            startup_error: nil,
            submit_when_ready?: false,
            status: :idle,
            error: nil,
            request: nil,
            finishing?: false,
            prepare_prompt?: false,
            project_instructions: [],
            coding_reviews: [],
            turns: [],
            active_turn: nil,
            next_turn_id: 0,
            pending_review: nil,
            selection: nil,
            previous_selection: nil,
            dirty?: true,
            render_scheduled?: false

  @type effect ::
          {:start_turn, String.t()}
          | {:start_turn, String.t(), map()}
          | {:prepare_prompt, String.t()}
          | {:apply_selection, map()}
          | {:await_turn, term()}
          | {:cancel_turn, term()}
          | {:respond_review, :approve | :deny, term(), term()}
          | :exit

  @type t :: %__MODULE__{}

  @spec new(term(), {pos_integer(), pos_integer()}, keyword()) :: t()
  def new(session, size, opts \\ []) do
    selection = Selection.init(opts)

    %__MODULE__{
      session: session,
      session_client: Keyword.get(opts, :session_client),
      size: size,
      runtime_status: Keyword.get(opts, :runtime_status, :ready),
      prepare_prompt?: Keyword.get(opts, :prepare_prompt, false),
      project_instructions: Keyword.get(opts, :project_instructions, []),
      history_limit: positive_limit(opts, :history_limit, @default_history_limit),
      turn_limit: positive_limit(opts, :turn_limit, @default_turn_limit),
      selection: selection
    }
  end

  @spec update(t(), term()) :: {t(), [effect()]}
  def update(%__MODULE__{status: :review} = state, {:terminal, {:text, text}})
      when text in ["a", "A", "y", "Y"],
      do: respond_to_review(state, :approve)

  def update(%__MODULE__{status: :review} = state, {:terminal, {:text, text}})
      when text in ["d", "D", "n", "N"],
      do: respond_to_review(state, :deny)

  def update(%__MODULE__{status: status} = state, {:terminal, {:text, _text}})
      when status in [:review, :responding_review],
      do: {state, []}

  def update(%__MODULE__{status: status} = state, {:terminal, {:paste, _text}})
      when status in [:review, :responding_review],
      do: {state, []}

  def update(%__MODULE__{status: status} = state, {:terminal, {:key, :newline}})
      when status in [:review, :responding_review],
      do: {state, []}

  def update(%__MODULE__{status: :resolving} = state, {:terminal, {kind, _value}})
      when kind in [:text, :paste],
      do: {state, []}

  def update(%__MODULE__{status: :resolving} = state, {:terminal, {:key, key}})
      when key in [:newline, :backspace, :left, :right, :up, :down],
      do: {state, []}

  def update(%__MODULE__{} = state, {:terminal, {:text, text}}) do
    edit(state, Editor.insert(state.editor, text))
  end

  def update(%__MODULE__{} = state, {:terminal, {:paste, text}}) do
    edit(state, Editor.insert(state.editor, text))
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :backspace}}),
    do: edit(state, Editor.backspace(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :left}}),
    do: changed(state, editor: Editor.left(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :right}}),
    do: changed(state, editor: Editor.right(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :newline}}),
    do: edit(state, Editor.newline(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :up}}), do: move_up(state)
  def update(%__MODULE__{} = state, {:terminal, {:key, :down}}), do: move_down(state)

  def update(%__MODULE__{} = state, {:terminal, {:key, :page_up}}) do
    offset = min(state.scroll_offset + scroll_page(state), @max_scroll_offset)
    changed(state, scroll_offset: offset)
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :page_down}}) do
    changed(state, scroll_offset: max(state.scroll_offset - scroll_page(state), 0))
  end

  def update(
        %__MODULE__{runtime_status: :starting, request: nil} = state,
        {:terminal, {:key, :enter}}
      ) do
    if String.trim(state.editor.text) == "" do
      {state, []}
    else
      changed(state, submit_when_ready?: true)
    end
  end

  def update(%__MODULE__{runtime_status: :failed} = state, {:terminal, {:key, :enter}}),
    do: {state, []}

  def update(%__MODULE__{status: status} = state, {:terminal, {:key, :enter}})
      when status in [:running, :resolving, :cancelling, :review, :responding_review],
      do: {state, []}

  def update(%__MODULE__{request: nil} = state, {:terminal, {:key, :enter}}) do
    prompt = String.trim(state.editor.text)

    if prompt == "" do
      {state, []}
    else
      submit_prompt(state, prompt)
    end
  end

  def update(%__MODULE__{} = state, {:prompt_ready, prompt, context}) do
    turn = Turn.new(state.next_turn_id, prompt, context)

    state = remember_prompt(state, state.pending_prompt || prompt)

    state = %{
      state
      | editor: Editor.clear(state.editor),
        pending_prompt: nil,
        scroll_offset: 0,
        messages: state.messages ++ [%{role: :user, content: turn.prompt}],
        streaming: "",
        status: :running,
        error: nil,
        active_turn: turn,
        next_turn_id: state.next_turn_id + 1,
        dirty?: true
    }

    {state, [{:start_turn, turn.prompt, context}]}
  end

  def update(%__MODULE__{} = state, {:prompt_error, reason}) do
    {%{
       state
       | pending_prompt: nil,
         selection: state.previous_selection || state.selection,
         previous_selection: nil,
         status: :error,
         error: format_error(reason),
         dirty?: true
     }, []}
  end

  def update(%__MODULE__{} = state, {:runtime_ready, session, instructions}) do
    submit? = state.submit_when_ready?

    state = %{
      state
      | session: session,
        runtime_status: :ready,
        startup_error: nil,
        submit_when_ready?: false,
        previous_selection: nil,
        status: :idle,
        error: nil,
        project_instructions: instructions,
        dirty?: true
    }

    prompt = String.trim(state.editor.text)

    if submit? and prompt != "" do
      submit_prompt(state, prompt)
    else
      {state, []}
    end
  end

  def update(%__MODULE__{} = state, {:runtime_failed, reason}) do
    {%{
       state
       | runtime_status: :failed,
         startup_error: reason,
         submit_when_ready?: false,
         status: :error,
         error: format_error(reason),
         dirty?: true
     }, []}
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :enter}}), do: {state, []}

  def update(%__MODULE__{request: nil} = state, {:terminal, {:key, key}})
      when key in [:escape, :ctrl_c],
      do: {state, [:exit]}

  def update(%__MODULE__{status: :cancelling} = state, {:terminal, {:key, :ctrl_c}}),
    do: {state, []}

  def update(%__MODULE__{request: request} = state, {:terminal, {:key, :ctrl_c}}) do
    {%{state | status: :cancelling, dirty?: true}, [{:cancel_turn, request}]}
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :escape}}), do: {state, []}
  def update(%__MODULE__{} = state, {:terminal, :eof}), do: {state, [:exit]}

  def update(%__MODULE__{} = state, {:terminal, {:resize, columns, rows}}) do
    changed(state, size: {columns, rows})
  end

  def update(%__MODULE__{} = state, {:turn_started, request}) do
    {turn, next_turn_id} = ensure_turn(state)
    turn = Turn.put_request(turn, request)

    state = %{
      state
      | request: request,
        active_turn: turn,
        next_turn_id: next_turn_id,
        finishing?: false,
        status: :running,
        dirty?: true
    }

    {state, [{:await_turn, request}]}
  end

  def update(%__MODULE__{active_turn: %Turn{} = turn} = state, {:jidoka, event}) do
    with {:ok, projection} <- EventProjection.project(event),
         {:ok, turn} <- Turn.apply_event(turn, projection) do
      state = %{
        state
        | active_turn: turn,
          streaming: turn.assistant,
          finishing?: turn.status == :terminal,
          dirty?: true
      }

      {state, []}
    else
      {:ignore, _reason} -> {state, []}
      {:error, _reason} -> {state, []}
    end
  end

  def update(%__MODULE__{} = state, {:jidoka, _event}), do: {state, []}

  def update(%__MODULE__{} = state, {:turn_result, {:ok, session, content}}) do
    finish(state, session, content, :idle, nil, outcome: :completed)
  end

  def update(%__MODULE__{} = state, {:turn_result, %RuntimeResult{status: :ok} = result}) do
    changes = result.coding_reviews |> Jido.Console.Coding.Review.normalize() |> retain(@review_limit)
    state = %{state | coding_reviews: changes}
    finish(state, result.session, result.content, :idle, nil, outcome: :completed, changes: changes)
  end

  def update(%__MODULE__{} = state, {:turn_result, %RuntimeResult{status: :pending_review} = result}) do
    pause_for_review(state, result)
  end

  def update(%__MODULE__{} = state, {:turn_result, %RuntimeResult{status: :hibernated} = result}) do
    finish(state, result.session, state.streaming, :interrupted, "Agent paused.", outcome: :hibernated)
  end

  def update(%__MODULE__{} = state, {:turn_result, %RuntimeResult{status: :cancelled} = result}) do
    finish(state, result.session, state.streaming, :idle, nil, outcome: :cancelled)
  end

  def update(%__MODULE__{} = state, {:turn_result, %RuntimeResult{status: :error} = result}) do
    error = format_error(result.error)
    state = if result.approval == :denied, do: state, else: put_review_failure(state, result.error)
    finish(state, result.session, state.streaming, :error, error, outcome: :failed)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:ok, session, content, reviews}}) do
    changes = Jido.Console.Coding.Review.normalize(reviews)
    state = %{state | coding_reviews: changes}
    finish(state, session, content, :idle, nil, outcome: :completed, changes: changes)
  end

  def update(%__MODULE__{} = state, {:coding_review, reviews}) do
    changes = reviews |> Jido.Console.Coding.Review.normalize() |> retain(@review_limit)
    state = put_active_changes(state, changes)
    changed(state, coding_reviews: changes)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:ok, content}}) do
    finish(state, state.session, content, :idle, nil, outcome: :completed)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:hibernate, session, _snapshot}}) do
    finish(state, session, state.streaming, :interrupted, "Agent paused for review.", outcome: :hibernated)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:hibernate, _snapshot}}) do
    finish(state, state.session, state.streaming, :interrupted, "Agent paused for review.", outcome: :hibernated)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:cancelled, _cancellation}}) do
    finish(state, state.session, state.streaming, :idle, nil, outcome: :cancelled)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:error, reason}}) do
    error = format_error(reason)
    finish(state, state.session, state.streaming, :error, error, outcome: :failed)
  end

  def update(%__MODULE__{request: request} = state, {:turn_result, request, result}) do
    update(state, {:turn_result, result})
  end

  def update(%__MODULE__{} = state, {:turn_result, _old_request, _result}), do: {state, []}

  def update(%__MODULE__{} = state, :render_scheduled),
    do: {%{state | render_scheduled?: true}, []}

  def update(%__MODULE__{} = state, :rendered),
    do: {%{state | dirty?: false, render_scheduled?: false}, []}

  def update(%__MODULE__{} = state, _event), do: {state, []}

  defp submit_prompt(state, prompt) do
    case Selection.handle(prompt, state.selection) do
      {:command, next, notice} ->
        apply_command(state, next, notice)

      :not_command ->
        start_selected_turn(state, prompt)
    end
  end

  defp start_selected_turn(state, prompt) do
    case Selection.admit(state.selection) do
      :ok ->
        enqueue_turn(state, prompt)

      {:error, reason} ->
        {%{state | status: :error, error: reason, dirty?: true}, []}
    end
  end

  defp enqueue_turn(%__MODULE__{prepare_prompt?: true} = state, prompt) do
    {%{state | pending_prompt: prompt, status: :resolving, error: nil, dirty?: true}, [{:prepare_prompt, prompt}]}
  end

  defp enqueue_turn(state, prompt) do
    turn = Turn.new(state.next_turn_id, prompt)

    state = remember_prompt(state, prompt)

    state = %{
      state
      | editor: Editor.clear(state.editor),
        pending_prompt: nil,
        scroll_offset: 0,
        messages: state.messages ++ [%{role: :user, content: turn.prompt}],
        streaming: "",
        status: :running,
        error: nil,
        active_turn: turn,
        next_turn_id: state.next_turn_id + 1,
        dirty?: true
    }

    {state, [{:start_turn, turn.prompt}]}
  end

  defp changed(state, updates) do
    state = struct!(state, Keyword.put(updates, :dirty?, true))
    {state, []}
  end

  defp edit(state, editor) do
    changed(state,
      editor: editor,
      history_index: nil,
      history_draft: nil
    )
  end

  defp move_up(state) do
    editor = Editor.up(state.editor)
    if editor == state.editor, do: previous_history(state), else: changed(state, editor: editor)
  end

  defp move_down(state) do
    editor = Editor.down(state.editor)
    if editor == state.editor, do: next_history(state), else: changed(state, editor: editor)
  end

  defp previous_history(%__MODULE__{history: []} = state), do: {state, []}

  defp previous_history(%__MODULE__{history_index: nil} = state) do
    index = length(state.history) - 1

    changed(state,
      editor: state.history |> Enum.at(index) |> Editor.from_text(),
      history_index: index,
      history_draft: state.editor.text
    )
  end

  defp previous_history(%__MODULE__{history_index: index} = state) do
    index = max(index - 1, 0)
    changed(state, editor: state.history |> Enum.at(index) |> Editor.from_text(), history_index: index)
  end

  defp next_history(%__MODULE__{history_index: nil} = state), do: {state, []}

  defp next_history(state) do
    index = state.history_index + 1

    if index < length(state.history) do
      changed(state, editor: state.history |> Enum.at(index) |> Editor.from_text(), history_index: index)
    else
      changed(state,
        editor: Editor.from_text(state.history_draft || ""),
        history_index: nil,
        history_draft: nil
      )
    end
  end

  defp remember_prompt(state, prompt) do
    history = if List.last(state.history) == prompt, do: state.history, else: state.history ++ [prompt]
    %{state | history: retain(history, state.history_limit), history_index: nil, history_draft: nil}
  end

  defp scroll_page(%__MODULE__{size: {_columns, rows}}), do: max(rows - 4, 1)

  defp finish(state, session, content, status, error, opts) do
    content = if is_binary(content) and content != "", do: content, else: state.streaming
    {turn, next_turn_id} = ensure_turn(state)

    turn =
      Turn.finish(
        turn,
        Keyword.fetch!(opts, :outcome),
        content,
        Keyword.merge([error: error], opts)
      )

    messages =
      if turn.assistant == "" do
        state.messages
      else
        state.messages ++ [%{role: :assistant, content: turn.assistant}]
      end

    messages = retain(messages, state.turn_limit * 2)
    turns = retain(state.turns ++ [turn], state.turn_limit)

    {%{
       state
       | session: session,
         messages: messages,
         streaming: "",
         status: status,
         error: error,
         request: nil,
         turns: turns,
         active_turn: nil,
         next_turn_id: next_turn_id,
         pending_review: nil,
         finishing?: false,
         dirty?: true
     }, []}
  end

  defp ensure_turn(%__MODULE__{active_turn: %Turn{} = turn} = state),
    do: {turn, state.next_turn_id}

  defp ensure_turn(%__MODULE__{} = state),
    do: {Turn.new(state.next_turn_id, ""), state.next_turn_id + 1}

  defp put_active_changes(%__MODULE__{active_turn: %Turn{} = turn} = state, changes),
    do: %{state | active_turn: Turn.put_changes(turn, changes)}

  defp put_active_changes(state, _changes), do: state

  defp put_review_failure(
         %__MODULE__{status: :responding_review, active_turn: %Turn{} = turn} = state,
         error
       ),
       do: %{state | active_turn: Turn.fail_review(turn, error)}

  defp put_review_failure(state, _error), do: state

  defp pause_for_review(state, %RuntimeResult{} = result) do
    {turn, next_turn_id} = ensure_turn(state)
    turn = Turn.put_reviews(turn, result.pending_reviews)

    {%{
       state
       | session: result.session,
         request: nil,
         active_turn: turn,
         next_turn_id: next_turn_id,
         pending_review: result,
         streaming: turn.assistant,
         status: :review,
         error: nil,
         finishing?: false,
         dirty?: true
     }, []}
  end

  defp respond_to_review(
         %__MODULE__{
           pending_review: %RuntimeResult{pending_reviews: [review | _]} = result,
           active_turn: %Turn{} = turn
         } = state,
         decision
       ) do
    turn = turn |> Turn.decide_review(review, decision) |> Turn.resume()

    {%{
       state
       | active_turn: turn,
         pending_review: nil,
         status: :responding_review,
         error: nil,
         dirty?: true
     }, [{:respond_review, decision, result, review}]}
  end

  defp respond_to_review(state, _decision), do: {state, []}

  defp format_error(reason) do
    reason
    |> Jido.Console.Error.normalize()
    |> Exception.message()
  rescue
    _exception -> inspect(reason)
  end

  defp retain(values, limit) when length(values) > limit, do: Enum.take(values, -limit)
  defp retain(values, _limit), do: values

  defp positive_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp apply_command(state, selection, notice) do
    previous = state.selection
    changed? = runtime_selection_changed?(previous, selection)

    state = %{
      state
      | selection: selection,
        previous_selection: if(changed?, do: previous),
        editor: Editor.clear(state.editor),
        messages: state.messages ++ [%{role: :system, content: notice}],
        status: if(changed?, do: :resolving, else: :idle),
        error: nil,
        dirty?: true
    }

    if changed?, do: {state, [{:apply_selection, selection}]}, else: {state, []}
  end

  defp runtime_selection_changed?(left, right) when is_map(left) and is_map(right) do
    left.model != right.model or left.profile_id != right.profile_id
  end

  defp runtime_selection_changed?(_left, _right), do: false
end
