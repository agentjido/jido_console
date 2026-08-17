defmodule Jido.Console.Tui.State do
  @moduledoc "Pure state transitions for the Jido TUI."

  alias Jido.Console.Tui.{Activity, Editor, SafeText, Selection, SemanticProjection, Turn}
  alias Jido.Console.Session.Request, as: SessionRequest

  @default_history_limit 100
  @default_turn_limit 100
  @review_limit 100
  @max_scroll_offset 1_000_000

  @schema Zoi.struct(
            __MODULE__,
            %{
              session: Zoi.any(),
              semantic_session_id: Zoi.string() |> Zoi.nullish(),
              semantic_sequence: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(0),
              size: Zoi.tuple({Zoi.integer() |> Zoi.positive(), Zoi.integer() |> Zoi.positive()}),
              session_client: Zoi.any() |> Zoi.nullish(),
              editor: Zoi.struct(Editor) |> Zoi.optional() |> Zoi.default(%Editor{}),
              history: Zoi.array(Zoi.string()) |> Zoi.optional() |> Zoi.default([]),
              history_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              history_draft: Zoi.string() |> Zoi.nullish(),
              history_limit: Zoi.integer() |> Zoi.positive() |> Zoi.optional() |> Zoi.default(@default_history_limit),
              scroll_offset: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(0),
              turn_limit: Zoi.integer() |> Zoi.positive() |> Zoi.optional() |> Zoi.default(@default_turn_limit),
              messages: Zoi.array(Zoi.map()) |> Zoi.optional() |> Zoi.default([]),
              activity: Zoi.any() |> Zoi.optional() |> Zoi.default(:idle),
              prepare_prompt?: Zoi.boolean() |> Zoi.optional() |> Zoi.default(false),
              project_instructions: Zoi.array(Zoi.map()) |> Zoi.optional() |> Zoi.default([]),
              coding_reviews: Zoi.array(Zoi.map()) |> Zoi.optional() |> Zoi.default([]),
              turns: Zoi.array() |> Zoi.optional() |> Zoi.default([]),
              next_turn_id: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(0),
              selection: Zoi.any() |> Zoi.nullish(),
              dirty?: Zoi.boolean() |> Zoi.optional() |> Zoi.default(true),
              render_scheduled?: Zoi.boolean() |> Zoi.optional() |> Zoi.default(false)
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type effect ::
          {:start_turn, String.t()}
          | {:start_turn, String.t(), map()}
          | {:prepare_prompt, String.t()}
          | {:apply_selection, map()}
          | {:cancel_turn, term()}
          | {:respond_review, :approve | :deny, SessionRequest.t(), term(), term()}
          | :exit

  @type t :: %__MODULE__{}

  @spec new(term(), {pos_integer(), pos_integer()}, keyword()) :: t()
  def new(session, size, opts \\ []) do
    selection = Selection.init(opts)

    state = %__MODULE__{
      session: session,
      session_client: Keyword.get(opts, :session_client),
      size: size,
      activity: Keyword.get(opts, :activity, :idle),
      prepare_prompt?: Keyword.get(opts, :prepare_prompt, false),
      project_instructions: Keyword.get(opts, :project_instructions, []),
      history_limit: positive_limit(opts, :history_limit, @default_history_limit),
      turn_limit: positive_limit(opts, :turn_limit, @default_turn_limit),
      selection: selection
    }

    restore_snapshot(
      state,
      Keyword.get(opts, :session_snapshot),
      Keyword.get(opts, :session_request)
    )
  end

  @doc "Restores renderer state from a bounded semantic session snapshot."
  @spec restore_snapshot(t(), map() | nil, SessionRequest.t() | nil) :: t()
  def restore_snapshot(state, snapshot, active_request \\ nil)

  def restore_snapshot(
        %__MODULE__{} = state,
        %{"family" => "delivery", "payload" => %{"snapshot" => semantic}},
        active_request
      )
      when is_map(semantic) do
    restore_semantic_state(state, semantic, active_request)
  end

  def restore_snapshot(%__MODULE__{} = state, %{"payload" => %{"state" => semantic}}, active_request)
      when is_map(semantic) do
    restore_semantic_state(state, semantic, active_request)
  end

  def restore_snapshot(%__MODULE__{} = state, _snapshot, _active_request), do: state

  defp restore_semantic_state(state, semantic, active_request) do
    transcript = Map.get(semantic, "transcript", [])
    transcript = if transcript == [], do: semantic_transcript(semantic["history"] || []), else: transcript

    restored =
      Enum.reduce(transcript, %{turns: [], messages: [], active: nil, next_id: 0}, fn event, acc ->
        restore_event(acc, event)
      end)

    active_turn = if restored.active, do: put_snapshot_request(restored.active, active_request), else: nil

    activity =
      case {active_turn, active_request} do
        {%Turn{} = turn, %SessionRequest{} = request} -> {:active, request, turn, :streaming}
        {%Turn{} = turn, _request} -> {:starting, {:turn, turn}}
        {nil, _request} -> state.activity
      end

    %{
      state
      | messages: retain(restored.messages, state.turn_limit * 2),
        turns: retain(restored.turns, state.turn_limit),
        next_turn_id: restored.next_id,
        activity: activity,
        semantic_session_id: semantic["session_id"],
        semantic_sequence: semantic["sequence"] || 0,
        dirty?: true
    }
  end

  @doc "Applies a complete ordered canonical batch as one local transaction."
  @spec apply_session_events(t(), [map()]) :: {:ok, t()} | {:error, term()}
  def apply_session_events(state, events) when is_list(events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, current} ->
      case apply_session_event(current, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Applies one exact next canonical event to renderer-local state."
  @spec apply_session_event(t(), map()) :: {:ok, t()} | {:error, term()}
  def apply_session_event(state, event) do
    payload = event["payload"] || %{}
    sequence = payload["sequence"]

    with {:ok, event} <- Jido.Console.Session.Event.validate(event),
         true <- event["session_id"] == state.semantic_session_id,
         true <- sequence == state.semantic_sequence + 1,
         request_id = request_id(state),
         {:ok, projection} <- SemanticProjection.project(event, request_id) do
      state = %{state | semantic_sequence: sequence}
      {:ok, apply_semantic_projection(state, event, projection)}
    else
      false -> {:error, :invalid_tui_event_order}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec active_request(t()) :: SessionRequest.t() | nil
  def active_request(%__MODULE__{activity: activity}), do: Activity.request(activity)

  @spec active_turn(t()) :: Turn.t() | nil
  def active_turn(%__MODULE__{activity: activity}), do: Activity.turn(activity)

  @spec startup_failure(t()) :: {:ok, term()} | :none
  def startup_failure(%__MODULE__{activity: {:failed, :startup, reason, _message}}), do: {:ok, reason}
  def startup_failure(%__MODULE__{}), do: :none

  @spec update(t(), term()) :: {t(), [effect()]}
  def update(%__MODULE__{activity: {:review, _, _, _, :awaiting}} = state, {:terminal, {:text, text}})
      when text in ["a", "A", "y", "Y"],
      do: respond_to_review(state, :approve)

  def update(%__MODULE__{activity: {:review, _, _, _, :awaiting}} = state, {:terminal, {:text, text}})
      when text in ["d", "D", "n", "N"],
      do: respond_to_review(state, :deny)

  def update(%__MODULE__{activity: {:review, _, _, _, _}} = state, {:terminal, {:text, _text}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, _}} = state, {:terminal, {:paste, _text}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, _}} = state, {:terminal, {:key, :newline}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:preparing, _}} = state, {:terminal, {kind, _value}})
      when kind in [:text, :paste],
      do: {state, []}

  def update(%__MODULE__{activity: {:preparing, _}} = state, {:terminal, {:key, key}})
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

  def update(%__MODULE__{activity: {:starting, {:runtime, _}}} = state, {:terminal, {:key, :enter}}) do
    if String.trim(state.editor.text) == "" do
      {state, []}
    else
      changed(state, activity: {:starting, {:runtime, :submit_when_ready}})
    end
  end

  def update(%__MODULE__{activity: {:failed, :startup, _, _}} = state, {:terminal, {:key, :enter}}),
    do: {state, []}

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, :enter}})
      when elem(activity, 0) in [:preparing, :starting, :active, :review, :cancelling],
      do: {state, []}

  def update(%__MODULE__{} = state, {:terminal, {:key, :enter}}) do
    prompt = String.trim(state.editor.text)

    if prompt == "" do
      {state, []}
    else
      submit_prompt(state, prompt)
    end
  end

  def update(%__MODULE__{activity: {:preparing, {:prompt, original}}} = state, {:prompt_ready, prompt, context}) do
    turn = Turn.new(state.next_turn_id, prompt, context)

    state = remember_prompt(state, original)

    state = %{
      state
      | editor: Editor.clear(state.editor),
        scroll_offset: 0,
        messages: state.messages ++ [%{role: :user, content: turn.prompt}],
        activity: {:starting, {:turn, turn}},
        next_turn_id: state.next_turn_id + 1,
        dirty?: true
    }

    {state, [{:start_turn, turn.prompt, context}]}
  end

  def update(%__MODULE__{activity: {:preparing, preparation}} = state, {:prompt_error, reason}) do
    selection =
      case preparation do
        {:selection, previous} -> previous
        {:prompt, _prompt} -> state.selection
      end

    {%{
       state
       | selection: selection,
         activity: {:failed, failure_kind(preparation), reason, format_error(reason)},
         dirty?: true
     }, []}
  end

  def update(%__MODULE__{} = state, {:runtime_ready, session, instructions}) do
    submit? = state.activity == {:starting, {:runtime, :submit_when_ready}}

    activity =
      case state.activity do
        {:starting, {:runtime, _queued}} -> :idle
        {:preparing, {:selection, _previous}} -> :idle
        other -> other
      end

    state = %{
      state
      | session: session,
        activity: activity,
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
       | activity: {:failed, :startup, reason, format_error(reason)},
         dirty?: true
     }, []}
  end

  def update(%__MODULE__{activity: {:starting, {:turn, turn}}} = state, {:terminal, {:key, :ctrl_c}}) do
    {%{state | activity: {:cancelling, turn, :before_start}, dirty?: true}, []}
  end

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, :escape}})
      when activity == :idle or elem(activity, 0) in [:preparing, :starting, :failed],
      do: {state, [:exit]}

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, key}})
      when key in [:escape, :ctrl_c] and (activity == :idle or elem(activity, 0) == :failed),
      do: {state, [:exit]}

  def update(%__MODULE__{activity: {:cancelling, _, _}} = state, {:terminal, {:key, :ctrl_c}}),
    do: {state, []}

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, :ctrl_c}}) do
    case {Activity.turn(activity), Activity.request(activity)} do
      {%Turn{} = turn, %SessionRequest{} = request} ->
        {%{state | activity: {:cancelling, turn, {:request, request}}, dirty?: true}, [{:cancel_turn, request}]}

      _other ->
        {state, [:exit]}
    end
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :escape}}), do: {state, []}
  def update(%__MODULE__{} = state, {:terminal, :eof}), do: {state, [:exit]}

  def update(%__MODULE__{} = state, {:terminal, {:resize, columns, rows}}) do
    changed(state, size: {columns, rows})
  end

  def update(
        %__MODULE__{activity: {:starting, {:turn, starting_turn}}} = state,
        {:turn_started, %SessionRequest{} = request}
      ) do
    {turn, next_turn_id} = ensure_turn(state, starting_turn)
    turn = Turn.put_request(turn, request)

    state = %{
      state
      | activity: started_activity(request, turn),
        next_turn_id: next_turn_id,
        dirty?: true
    }

    {state, []}
  end

  def update(
        %__MODULE__{activity: {:cancelling, turn, :before_start}} = state,
        {:turn_started, %SessionRequest{} = request}
      ) do
    turn = Turn.put_request(turn, request)
    state = %{state | activity: {:cancelling, turn, {:request, request}}, dirty?: true}
    {state, [{:cancel_turn, request}]}
  end

  def update(%__MODULE__{} = state, {:turn_started, _request}), do: {state, []}

  def update(%__MODULE__{} = state, {:session_event, event}) do
    case apply_session_event(state, event) do
      {:ok, state} -> {state, []}
      {:error, _reason} -> {state, []}
    end
  end

  def update(%__MODULE__{activity: activity} = state, {:turn_result, result}) do
    case Activity.turn(activity) do
      %Turn{} -> apply_turn_result(state, result)
      nil -> {state, []}
    end
  end

  def update(%__MODULE__{} = state, {:turn_result, request, result}) do
    if Activity.request(state.activity) == request do
      update(state, {:turn_result, result})
    else
      {state, []}
    end
  end

  def update(%__MODULE__{} = state, {:coding_review, reviews}) do
    changes = reviews |> Jido.Console.Coding.Review.project_candidates() |> retain(@review_limit)
    state = put_active_changes(state, changes)
    changed(state, coding_reviews: changes)
  end

  def update(%__MODULE__{} = state, :render_scheduled),
    do: {%{state | render_scheduled?: true}, []}

  def update(%__MODULE__{} = state, :rendered),
    do: {%{state | dirty?: false, render_scheduled?: false}, []}

  def update(%__MODULE__{} = state, _event), do: {state, []}

  defp apply_turn_result(state, {:error, reason}) do
    error = format_error(reason)
    finish(state, state.session, Activity.streaming(state.activity), {:failed, :turn, reason, error}, outcome: :failed)
  end

  defp apply_turn_result(state, _result), do: {state, []}

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
        {%{state | activity: {:failed, :selection, reason, reason}, dirty?: true}, []}
    end
  end

  defp enqueue_turn(%__MODULE__{prepare_prompt?: true} = state, prompt) do
    {%{state | activity: {:preparing, {:prompt, prompt}}, dirty?: true}, [{:prepare_prompt, prompt}]}
  end

  defp enqueue_turn(state, prompt) do
    turn = Turn.new(state.next_turn_id, prompt)

    state = remember_prompt(state, prompt)

    state = %{
      state
      | editor: Editor.clear(state.editor),
        scroll_offset: 0,
        messages: state.messages ++ [%{role: :user, content: turn.prompt}],
        activity: {:starting, {:turn, turn}},
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

  defp finish(state, session, content, next_activity, opts) do
    error = Activity.error(next_activity)
    content = if is_binary(content) and content != "", do: content, else: Activity.streaming(state.activity)
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
         activity: next_activity,
         turns: turns,
         next_turn_id: next_turn_id,
         dirty?: true
     }, []}
  end

  defp ensure_turn(%__MODULE__{} = state) do
    case Activity.turn(state.activity) do
      %Turn{} = turn -> {turn, state.next_turn_id}
      nil -> {Turn.new(state.next_turn_id, ""), state.next_turn_id + 1}
    end
  end

  defp ensure_turn(%__MODULE__{} = state, %Turn{} = turn), do: {turn, state.next_turn_id}

  defp put_active_changes(%__MODULE__{} = state, changes) do
    case Activity.turn(state.activity) do
      %Turn{} = turn -> %{state | activity: Activity.replace_turn(state.activity, Turn.put_changes(turn, changes))}
      nil -> state
    end
  end

  defp respond_to_review(
         %__MODULE__{activity: {:review, request, turn, event, :awaiting}} = state,
         decision
       )
       when is_map(event) and not is_struct(event) do
    review = List.first(turn.reviews) || %{}
    turn = turn |> Turn.decide_review(review, decision) |> Turn.resume()

    {%{
       state
       | activity: {:review, request, turn, event, {:responding, decision}},
         dirty?: true
     }, [{:respond_review, decision, request, event, review}]}
  end

  defp respond_to_review(state, _decision), do: {state, []}

  defp started_activity(request, %Turn{} = turn) do
    if Enum.any?(turn.reviews, &(Map.get(&1, :status) == :pending)) do
      {:review, request, turn, %{}, :awaiting}
    else
      {:active, request, turn, :streaming}
    end
  end

  defp failure_kind({:prompt, _prompt}), do: :preparation
  defp failure_kind({:selection, _previous}), do: :selection

  defp format_error(reason) do
    Jido.Console.Error.message(reason)
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
        editor: Editor.clear(state.editor),
        messages: state.messages ++ [%{role: :system, content: notice}],
        activity: if(changed?, do: {:preparing, {:selection, previous}}, else: :idle),
        dirty?: true
    }

    if changed?, do: {state, [{:apply_selection, selection}]}, else: {state, []}
  end

  defp runtime_selection_changed?(left, right) when is_map(left) and is_map(right) do
    left.model != right.model or left.profile_id != right.profile_id
  end

  defp runtime_selection_changed?(_left, _right), do: false

  defp restore_event(acc, %{"type" => "run_started", "payload" => payload}) do
    prompt = Map.get(payload, "prompt", "")
    turn = Turn.new(acc.next_id, prompt) |> Turn.put_request(%{request_id: payload["turn_id"]})
    messages = if prompt == "", do: acc.messages, else: acc.messages ++ [%{role: :user, content: prompt}]
    %{acc | active: turn, messages: messages, next_id: acc.next_id + 1}
  end

  defp restore_event(%{active: %Turn{} = turn} = acc, %{"type" => "model_delta", "payload" => payload}) do
    delta = payload["text"] || ""
    assistant = String.slice(turn.assistant <> SafeText.clean(delta), 0, 200_000)
    %{acc | active: %{turn | assistant: assistant}}
  end

  defp restore_event(%{active: %Turn{} = turn} = acc, %{"type" => type, "payload" => payload})
       when type in ["run_completed", "run_failed"] do
    status = if type == "run_completed", do: :completed, else: :failed
    content = payload["content"] || turn.assistant
    error = payload["error"] || payload["reason"]
    turn = Turn.finish(turn, status, content, error: error)

    messages =
      if turn.assistant == "", do: acc.messages, else: acc.messages ++ [%{role: :assistant, content: turn.assistant}]

    %{acc | active: nil, messages: messages, turns: acc.turns ++ [turn]}
  end

  defp restore_event(acc, _event), do: acc

  defp put_snapshot_request(turn, %SessionRequest{} = request), do: Turn.put_request(turn, request)
  defp put_snapshot_request(turn, _request), do: turn

  defp semantic_transcript(history) do
    Enum.reject(history, &(&1["type"] in ~w(control_requested control_completed queue_changed)))
  end

  defp request_id(state) do
    case Activity.request(state.activity) do
      %SessionRequest{request_id: request_id} -> request_id
      _request -> nil
    end
  end

  defp apply_semantic_projection(state, event, projection) do
    case event["type"] do
      type when type in ["run_completed", "run_failed", "session_failed"] ->
        finish_semantic(state, event, projection)

      "permission_requested" ->
        apply_permission_request(state, event, projection)

      "permission_decided" ->
        apply_permission_decision(state, projection)

      "control_completed" ->
        apply_control_result(state, event)

      _type ->
        apply_turn_projection(state, projection)
    end
  end

  defp apply_turn_projection(state, projection) do
    case Activity.turn(state.activity) do
      %Turn{} = turn ->
        case Turn.apply_event(turn, projection) do
          {:ok, turn} -> %{state | activity: Activity.replace_turn(state.activity, turn), dirty?: true}
          {:ignore, _reason} -> state
        end

      nil ->
        state
    end
  end

  defp apply_permission_request(state, event, projection) do
    state = apply_turn_projection(state, projection)

    case {Activity.request(state.activity), Activity.turn(state.activity)} do
      {%SessionRequest{} = request, %Turn{} = turn} ->
        %{state | activity: {:review, request, turn, event, :awaiting}, dirty?: true}

      _other ->
        state
    end
  end

  defp apply_permission_decision(state, projection) do
    state = apply_turn_projection(state, projection)

    case state.activity do
      {:review, request, turn, _event, _status} ->
        %{state | activity: {:active, request, turn, :streaming}, dirty?: true}

      _activity ->
        state
    end
  end

  defp finish_semantic(state, event, projection) do
    payload = event["payload"]
    status = projection.data.status
    content = payload["content"] || Activity.streaming(state.activity)
    reason = payload["reason"]
    changes = get_in(payload, ["view", "coding_reviews"]) || []
    state = %{state | coding_reviews: retain(changes, @review_limit)}

    next_activity =
      case status do
        value when value in [:completed, :cancelled] -> :idle
        :hibernated -> {:failed, :hibernated, reason, "Agent paused."}
        :failed -> {:failed, :turn, reason, format_error(reason)}
      end

    {state, []} =
      finish(state, state.session, content, next_activity,
        outcome: status,
        changes: changes
      )

    state
  end

  defp apply_control_result(state, event) do
    case get_in(event, ["payload", "result"]) do
      %{"status" => "error", "reason" => reason}
      when reason in ["request_already_finished", ":request_already_finished"] ->
        state

      %{"status" => "error", "reason" => reason} ->
        if Activity.turn(state.activity) do
          {state, []} =
            finish(
              state,
              state.session,
              Activity.streaming(state.activity),
              {:failed, :turn, reason, format_error(reason)},
              outcome: :failed
            )

          state
        else
          state
        end

      _result ->
        state
    end
  end
end
