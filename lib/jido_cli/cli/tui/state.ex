defmodule Jido.Cli.Tui.State do
  @moduledoc "Pure state transitions for the Jido TUI."

  alias Jido.Cli.Tui.{Editor, EventProjection, Turn}
  alias Jido.Cli.Runtime.Jidoka.Result, as: RuntimeResult

  @enforce_keys [:session, :size]
  defstruct session: nil,
            size: nil,
            editor: %Editor{},
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
            dirty?: true,
            render_scheduled?: false

  @type effect ::
          {:start_turn, String.t()}
          | {:start_turn, String.t(), map()}
          | {:prepare_prompt, String.t()}
          | {:await_turn, term()}
          | {:cancel_turn, term()}
          | {:respond_review, :approve | :deny, term(), term()}
          | :exit

  @type t :: %__MODULE__{}

  @spec new(term(), {pos_integer(), pos_integer()}, keyword()) :: t()
  def new(session, size, opts \\ []) do
    %__MODULE__{
      session: session,
      size: size,
      runtime_status: Keyword.get(opts, :runtime_status, :ready),
      prepare_prompt?: Keyword.get(opts, :prepare_prompt, false),
      project_instructions: Keyword.get(opts, :project_instructions, [])
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

  def update(%__MODULE__{} = state, {:terminal, {:text, text}}) do
    changed(state, editor: Editor.insert(state.editor, text))
  end

  def update(%__MODULE__{} = state, {:terminal, {:paste, text}}) do
    changed(state, editor: Editor.insert(state.editor, text))
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :backspace}}),
    do: changed(state, editor: Editor.backspace(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :left}}),
    do: changed(state, editor: Editor.left(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :right}}),
    do: changed(state, editor: Editor.right(state.editor))

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

    state = %{
      state
      | editor: Editor.clear(state.editor),
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
    {%{state | status: :error, error: format_error(reason), dirty?: true}, []}
  end

  def update(%__MODULE__{} = state, {:runtime_ready, session, instructions}) do
    submit? = state.submit_when_ready?

    state = %{
      state
      | session: session,
        runtime_status: :ready,
        startup_error: nil,
        submit_when_ready?: false,
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
    changes = Jido.Cli.Coding.Review.normalize(result.coding_reviews)
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
    changes = Jido.Cli.Coding.Review.normalize(reviews)
    state = %{state | coding_reviews: changes}
    finish(state, session, content, :idle, nil, outcome: :completed, changes: changes)
  end

  def update(%__MODULE__{} = state, {:coding_review, reviews}) do
    changes = Jido.Cli.Coding.Review.normalize(reviews)
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

  defp submit_prompt(%__MODULE__{prepare_prompt?: true} = state, prompt) do
    {%{state | status: :resolving, error: nil, dirty?: true}, [{:prepare_prompt, prompt}]}
  end

  defp submit_prompt(state, prompt) do
    turn = Turn.new(state.next_turn_id, prompt)

    state = %{
      state
      | editor: Editor.clear(state.editor),
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

    {%{
       state
       | session: session,
         messages: messages,
         streaming: "",
         status: status,
         error: error,
         request: nil,
         turns: state.turns ++ [turn],
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

  defp format_error(%{__exception__: true} = error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) do
    Jidoka.Error.format(reason)
  rescue
    _exception -> inspect(reason)
  end
end
