defmodule Jido.Cli.Tui.State do
  @moduledoc "Pure state transitions for the Jido TUI."

  alias Jido.Cli.Tui.Editor
  alias Jidoka.Stream, as: JidokaStream

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
            dirty?: true,
            render_scheduled?: false

  @type effect ::
          {:start_turn, String.t()}
          | {:start_turn, String.t(), map()}
          | {:prepare_prompt, String.t()}
          | {:finish_turn, term()}
          | {:cancel_turn, term()}
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
    state = %{
      state
      | editor: Editor.clear(state.editor),
        messages: state.messages ++ [%{role: :user, content: prompt}],
        streaming: "",
        status: :running,
        error: nil,
        dirty?: true
    }

    {state, [{:start_turn, prompt, context}]}
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

  def update(%__MODULE__{request: request} = state, {:terminal, {:key, :ctrl_c}}) do
    {%{state | status: :cancelling, dirty?: true}, [{:cancel_turn, request}]}
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :escape}}), do: {state, []}
  def update(%__MODULE__{} = state, {:terminal, :eof}), do: {state, [:exit]}

  def update(%__MODULE__{} = state, {:terminal, {:resize, columns, rows}}) do
    changed(state, size: {columns, rows})
  end

  def update(%__MODULE__{} = state, {:turn_started, request}) do
    changed(state, request: request, finishing?: false, status: :running)
  end

  def update(%__MODULE__{request: nil} = state, {:jidoka, _event}), do: {state, []}

  def update(%__MODULE__{} = state, {:jidoka, event}) do
    if request_matches?(state.request, event) do
      delta = JidokaStream.text_delta(event)
      state = if is_binary(delta), do: %{state | streaming: state.streaming <> delta}, else: state
      state = %{state | dirty?: true}

      if JidokaStream.terminal?(event) and not state.finishing? do
        {%{state | finishing?: true}, [{:finish_turn, state.request}]}
      else
        {state, []}
      end
    else
      {state, []}
    end
  end

  def update(%__MODULE__{} = state, {:turn_result, {:ok, session, content}}) do
    finish(state, session, content, :idle, nil)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:ok, session, content, reviews}}) do
    state = %{state | coding_reviews: Jido.Cli.CodingReview.normalize(reviews)}
    finish(state, session, content, :idle, nil)
  end

  def update(%__MODULE__{} = state, {:coding_review, reviews}) do
    changed(state, coding_reviews: Jido.Cli.CodingReview.normalize(reviews))
  end

  def update(%__MODULE__{} = state, {:turn_result, {:ok, content}}) do
    finish(state, state.session, content, :idle, nil)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:hibernate, session, _snapshot}}) do
    finish(state, session, state.streaming, :interrupted, "Agent paused for review.")
  end

  def update(%__MODULE__{} = state, {:turn_result, {:hibernate, _snapshot}}) do
    finish(state, state.session, state.streaming, :interrupted, "Agent paused for review.")
  end

  def update(%__MODULE__{} = state, {:turn_result, {:cancelled, _cancellation}}) do
    finish(state, state.session, state.streaming, :idle, nil)
  end

  def update(%__MODULE__{} = state, {:turn_result, {:error, reason}}) do
    finish(state, state.session, state.streaming, :error, format_error(reason))
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
    state = %{
      state
      | editor: Editor.clear(state.editor),
        messages: state.messages ++ [%{role: :user, content: prompt}],
        streaming: "",
        status: :running,
        error: nil,
        dirty?: true
    }

    {state, [{:start_turn, prompt}]}
  end

  defp changed(state, updates) do
    state = struct!(state, Keyword.put(updates, :dirty?, true))
    {state, []}
  end

  defp finish(state, session, content, status, error) do
    content = if is_binary(content) and content != "", do: content, else: state.streaming

    messages =
      if content == "" do
        state.messages
      else
        state.messages ++ [%{role: :assistant, content: content}]
      end

    {%{
       state
       | session: session,
         messages: messages,
         streaming: "",
         status: status,
         error: error,
         request: nil,
         finishing?: false,
         dirty?: true
     }, []}
  end

  defp request_matches?(%{request_id: request_id}, %{request_id: request_id}), do: true
  defp request_matches?(%{request_id: _request_id}, %{request_id: _other}), do: false
  defp request_matches?(_request, _event), do: true

  defp format_error(%{__exception__: true} = error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) do
    Jidoka.Error.format(reason)
  rescue
    _exception -> inspect(reason)
  end
end
