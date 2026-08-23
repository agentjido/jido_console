defmodule Jido.Console.Tui.State do
  @moduledoc "Pure state transitions for the Jido TUI."

  alias Jido.Console.Error
  alias Jido.Console.Tui.{Activity, Autocomplete, Command, Editor, SafeText, Selection, Turn}
  alias Jido.Console.Session.View, as: SessionView
  alias TermUI.Event
  alias TermUI.Widget.TextArea

  @default_history_limit 100
  @default_turn_limit 100
  @review_limit 100
  @command_notice_limit 20
  @completion_row_limit 5
  @max_scroll_offset 1_000_000

  @schema Zoi.struct(
            __MODULE__,
            %{
              session: Zoi.any(),
              size: Zoi.tuple({Zoi.integer() |> Zoi.positive(), Zoi.integer() |> Zoi.positive()}),
              session_client: Zoi.any() |> Zoi.nullish(),
              editor: Zoi.struct(TextArea) |> Zoi.optional() |> Zoi.default(Editor.new()),
              completion: Zoi.struct(Autocomplete) |> Zoi.optional() |> Zoi.default(%Autocomplete{}),
              history: Zoi.array(Zoi.string()) |> Zoi.optional() |> Zoi.default([]),
              history_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              history_draft: Zoi.string() |> Zoi.nullish(),
              history_limit: Zoi.integer() |> Zoi.positive() |> Zoi.optional() |> Zoi.default(@default_history_limit),
              scroll_offset: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(0),
              turn_limit: Zoi.integer() |> Zoi.positive() |> Zoi.optional() |> Zoi.default(@default_turn_limit),
              messages: Zoi.array(Zoi.map()) |> Zoi.optional() |> Zoi.default([]),
              command_notices: Zoi.array(Zoi.string()) |> Zoi.optional() |> Zoi.default([]),
              startup: Zoi.enum([:starting, :ready]) |> Zoi.optional() |> Zoi.default(:ready),
              activity: Zoi.any() |> Zoi.optional() |> Zoi.default(:idle),
              project_root: Zoi.string() |> Zoi.nullish(),
              project_instructions: Zoi.array(Zoi.map()) |> Zoi.optional() |> Zoi.default([]),
              coding_reviews: Zoi.array(Zoi.map()) |> Zoi.optional() |> Zoi.default([]),
              turns: Zoi.array() |> Zoi.optional() |> Zoi.default([]),
              next_turn_id: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(0),
              selection: Zoi.any() |> Zoi.nullish()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type effect ::
          {:start_turn, String.t()}
          | {:select_model, String.t()}
          | {:cancel_turn, term()}
          | {:copy, String.t()}
          | {:respond_review, :approve | :deny, map(), term(), term()}
          | :exit

  @type t :: unquote(Zoi.type_spec(@schema))

  @spec new(term(), {pos_integer(), pos_integer()}, keyword()) :: t()
  def new(session, size, opts \\ []) do
    selection = Selection.init(opts)

    state = %__MODULE__{
      session: session,
      session_client: Keyword.get(opts, :session_client),
      size: size,
      startup: Keyword.get(opts, :startup, :ready),
      activity: Keyword.get(opts, :activity, :idle),
      project_root: Keyword.get(opts, :project_root),
      project_instructions: Keyword.get(opts, :project_instructions, []),
      history_limit: positive_limit(opts, :history_limit, @default_history_limit),
      turn_limit: positive_limit(opts, :turn_limit, @default_turn_limit),
      selection: selection
    }

    recompute_completion(state)
  end

  @doc false
  @spec runtime_ready(t(), term(), SessionView.t()) :: {t(), [effect()]}
  def runtime_ready(%__MODULE__{} = state, session_client, %SessionView{} = view) do
    queued_prompt = queued_prompt(state)

    state =
      state
      |> Map.put(:startup, :ready)
      |> Map.put(:session_client, session_client)
      |> restore_view(view)

    case {queued_prompt, startup_failure(state)} do
      {_prompt, {:ok, _reason}} ->
        {state, []}

      {prompt, :none} when is_binary(prompt) ->
        start_selected_turn(state, prompt)

      {nil, :none} ->
        {state, []}
    end
  end

  defp queued_prompt(%__MODULE__{activity: {:starting, {:turn, %Turn{prompt: prompt}}}}), do: prompt
  defp queued_prompt(%__MODULE__{}), do: nil

  @doc "Replaces renderer state from one complete Session.View."
  @spec restore_view(t(), SessionView.t()) :: t()
  def restore_view(%__MODULE__{} = state, %SessionView{} = view) do
    messages = Enum.map(view.transcript, &view_message/1)
    turns = messages |> transcript_turns(state.turn_limit) |> restore_history_outcomes(view.history, state.turn_limit)
    {activity, reviews} = view_activity(view, length(turns))
    active_turn_count = if is_nil(view.active), do: 0, else: 1

    %{
      state
      | session: view,
        selection: restore_model_selection(state.selection, view.model),
        messages: messages,
        turns: turns,
        next_turn_id: length(turns) + active_turn_count,
        activity: activity,
        coding_reviews: reviews
    }
    |> recompute_completion()
  end

  @doc "Returns the completion rows that fit the current normal layout."
  @spec completion_slice(t()) :: %{
          rows: [Autocomplete.candidate()],
          offset: non_neg_integer(),
          selected_index: non_neg_integer() | nil,
          interactive?: boolean()
        }
  def completion_slice(%__MODULE__{} = state) do
    if review?(state) do
      Autocomplete.visible_slice(%Autocomplete{}, 0)
    else
      Autocomplete.visible_slice(state.completion, completion_capacity(state))
    end
  end

  @spec active_request(t()) :: map() | nil
  def active_request(%__MODULE__{activity: activity}), do: Activity.request(activity)

  @spec active_turn(t()) :: Turn.t() | nil
  def active_turn(%__MODULE__{activity: activity}), do: Activity.turn(activity)

  @spec startup_failure(t()) :: {:ok, term()} | :none
  def startup_failure(%__MODULE__{activity: {:failed, :startup, reason, _message}}), do: {:ok, reason}
  def startup_failure(%__MODULE__{}), do: :none

  @spec update(t(), term()) :: {t(), [effect()]}
  def update(%__MODULE__{activity: {:review, _, _, _, {:responding, _}}} = state, {:terminal, %Event.Text{}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, {:responding, _}}} = state, {:terminal, %Event.Paste{}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, {:responding, _}}} = state, {:terminal, %Event.Key{}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, {:responding, _}}} = state, {:terminal, %Event.Mouse{}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, :awaiting}} = state, {:terminal, %Event.Text{text: text}}),
    do: update(state, {:terminal, {:text, text}})

  def update(%__MODULE__{activity: {:review, _, _, _, _}} = state, {:terminal, %Event.Paste{}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, _}} = state, {:terminal, %Event.Key{key: :enter}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:review, _, _, _, _}} = state, {:terminal, %Event.Key{key: :tab}}),
    do: {state, []}

  def update(%__MODULE__{} = state, {:terminal, %Event.Text{} = event}),
    do: editor_event(state, event)

  def update(%__MODULE__{} = state, {:terminal, %Event.Paste{} = event}),
    do: editor_event(state, event)

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: key, modifiers: modifiers}})
      when key in ["j", :enter] do
    if :ctrl in modifiers,
      do: editor_event(state, Event.key(:enter)),
      else: update(state, {:terminal, {:key, :enter}})
  end

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: "c", modifiers: modifiers} = event}) do
    if :ctrl in modifiers and Editor.selection?(state.editor),
      do: editor_event(state, event),
      else: update(state, {:terminal, {:key, if(:ctrl in modifiers, do: :ctrl_c, else: "c")}})
  end

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: key} = event})
      when key in ["a", "x", :backspace, :delete, :left, :right, :home, :end],
      do: editor_event(state, event)

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: :tab, modifiers: []}}),
    do: update(state, {:terminal, {:key, :tab}})

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: :tab}}), do: {state, []}

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: key, modifiers: modifiers} = event})
      when key in [:up, :down] do
    cond do
      modifiers == [] -> update(state, {:terminal, {:key, key}})
      :shift in modifiers -> editor_event(state, event)
      true -> move_editor_or_history(state, key)
    end
  end

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: key}})
      when key in [:page_up, :page_down],
      do: update(state, {:terminal, {:key, key}})

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: :escape, modifiers: []}}),
    do: update(state, {:terminal, {:key, :escape}})

  def update(%__MODULE__{} = state, {:terminal, %Event.Key{key: :escape}}),
    do: existing_escape(state)

  def update(%__MODULE__{} = state, {:terminal, %Event.Mouse{} = event}),
    do: editor_mouse(state, event)

  def update(%__MODULE__{} = state, {:terminal, %Event.Resize{width: width, height: height}}),
    do: update(state, {:terminal, {:resize, width, height}})

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

  def update(%__MODULE__{} = state, {:terminal, {:text, text}}) do
    edit(state, Editor.insert(state.editor, text))
  end

  def update(%__MODULE__{} = state, {:terminal, {:paste, text}}) do
    edit(state, Editor.insert(state.editor, text))
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :backspace}}),
    do: edit(state, Editor.backspace(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :left}}),
    do: replace_editor(state, Editor.left(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :right}}),
    do: replace_editor(state, Editor.right(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, key}})
      when key in [:delete, :home, :end],
      do: editor_event(state, Event.key(key))

  def update(%__MODULE__{} = state, {:terminal, {:key, :newline}}),
    do: edit(state, Editor.newline(state.editor))

  def update(%__MODULE__{} = state, {:terminal, {:key, :tab}}), do: complete(state)

  def update(%__MODULE__{} = state, {:terminal, {:key, :up}}),
    do: move_completion_or_editor(state, :up)

  def update(%__MODULE__{} = state, {:terminal, {:key, :down}}),
    do: move_completion_or_editor(state, :down)

  def update(%__MODULE__{} = state, {:terminal, {:key, :page_up}}) do
    offset = min(state.scroll_offset + scroll_page(state), @max_scroll_offset)
    changed(state, scroll_offset: offset)
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :page_down}}) do
    changed(state, scroll_offset: max(state.scroll_offset - scroll_page(state), 0))
  end

  def update(%__MODULE__{activity: {:failed, :startup, _, _}} = state, {:terminal, {:key, :enter}}),
    do: {state, []}

  def update(%__MODULE__{activity: {:active, _, _, _}} = state, {:terminal, {:key, :enter}}) do
    prompt = state.editor |> Editor.value() |> String.trim()

    if prompt == "" do
      {state, []}
    else
      submit_prompt(state, prompt)
    end
  end

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, :enter}})
      when elem(activity, 0) in [:starting, :active, :review, :cancelling],
      do: {state, []}

  def update(%__MODULE__{} = state, {:terminal, {:key, :enter}}) do
    prompt = state.editor |> Editor.value() |> String.trim()

    if prompt == "" do
      {state, []}
    else
      submit_prompt(state, prompt)
    end
  end

  def update(%__MODULE__{activity: {:starting, {:turn, turn}}} = state, {:terminal, {:key, :ctrl_c}}) do
    {%{state | activity: {:cancelling, turn, :before_start}}, []}
  end

  def update(%__MODULE__{} = state, {:terminal, {:key, :escape}}) do
    if completion_visible?(state) and not review?(state),
      do: {%{state | completion: %Autocomplete{}}, []},
      else: existing_escape(state)
  end

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, :ctrl_c}})
      when activity == :idle or elem(activity, 0) == :failed,
      do: {state, [:exit]}

  def update(%__MODULE__{activity: {:cancelling, _, _}} = state, {:terminal, {:key, :ctrl_c}}),
    do: {state, []}

  def update(%__MODULE__{activity: activity} = state, {:terminal, {:key, :ctrl_c}}) do
    case {Activity.turn(activity), Activity.request(activity)} do
      {%Turn{} = turn, request} when is_map(request) ->
        {%{state | activity: {:cancelling, turn, {:request, request}}}, [{:cancel_turn, request}]}

      _other ->
        {state, [:exit]}
    end
  end

  def update(%__MODULE__{} = state, {:terminal, :eof}), do: {state, [:exit]}

  def update(%__MODULE__{} = state, {:terminal, {:resize, columns, rows}}) do
    state
    |> struct!(size: {columns, rows})
    |> recompute_completion()
    |> unchanged()
  end

  def update(
        %__MODULE__{activity: {:starting, {:turn, starting_turn}}} = state,
        {:turn_started, %{} = request}
      ) do
    {turn, next_turn_id} = ensure_turn(state, starting_turn)
    turn = Turn.put_request(turn, request)

    state = %{
      state
      | activity: started_activity(request, turn),
        next_turn_id: next_turn_id
    }

    {state, []}
  end

  def update(
        %__MODULE__{activity: {:cancelling, turn, :before_start}} = state,
        {:turn_started, %{} = request}
      ) do
    turn = Turn.put_request(turn, request)
    state = %{state | activity: {:cancelling, turn, {:request, request}}}
    {state, [{:cancel_turn, request}]}
  end

  def update(%__MODULE__{} = state, {:turn_started, _request}), do: {state, []}

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

  def update(%__MODULE__{} = state, {:model_selected, model}) when is_map(model) do
    identity = Map.get(model, "identity", Map.get(model, :identity, "unknown"))
    tier = Map.get(model, "tier", Map.get(model, :tier, "unknown"))
    notice(state, "Selected model #{identity} (#{tier})")
  end

  def update(%__MODULE__{} = state, {:command_error, reason}) do
    notice(state, format_error(reason))
  end

  def update(%__MODULE__{} = state, _event), do: {state, []}

  defp apply_turn_result(state, {:error, reason}) do
    error = format_error(reason)
    finish(state, state.session, Activity.streaming(state.activity), {:failed, :turn, reason, error}, outcome: :failed)
  end

  defp apply_turn_result(state, _result), do: {state, []}

  defp submit_prompt(state, prompt) do
    case Command.parse(prompt) do
      :prompt -> submit_regular_prompt(state, prompt)
      {:command, action} -> submit_command(state, action)
      {:error, error} -> notice(state, Exception.message(error))
    end
  end

  defp submit_regular_prompt(%__MODULE__{activity: {:active, _, _, _}} = state, prompt) do
    state = remember_prompt(state, prompt)

    state =
      state
      |> Map.put(:editor, Editor.clear(state.editor))
      |> Map.put(:scroll_offset, 0)
      |> recompute_completion()

    {state, [{:start_turn, prompt}]}
  end

  defp submit_regular_prompt(state, prompt), do: start_selected_turn(state, prompt)

  defp submit_command(state, :help), do: notice(state, Command.help())

  defp submit_command(state, :list_models) do
    case Selection.list_models(state.selection) do
      {:ok, models} -> notice(state, models)
      {:error, error} -> notice(state, Exception.message(error))
    end
  end

  defp submit_command(state, {:select_model, identity}) do
    cond do
      state.selection.model_locked? ->
        invalid_command_notice(
          state,
          "Model selection is locked after the first prompt is accepted",
          %{command: "model", reason: :model_locked}
        )

      is_nil(state.session_client) ->
        invalid_command_notice(
          state,
          "Jido is still starting. Try the model command again when it is ready.",
          %{command: "model", reason: :session_not_ready}
        )

      true ->
        state =
          state
          |> Map.put(:editor, Editor.clear(state.editor))
          |> Map.put(:scroll_offset, 0)
          |> recompute_completion()

        {state, [{:select_model, identity}]}
    end
  end

  defp submit_command(state, :list_profiles), do: notice(state, Selection.list_profiles())

  defp submit_command(state, {:select_profile, profile_id}) do
    notice(state, Selection.profile_notice(profile_id))
  end

  defp start_selected_turn(state, prompt) do
    case Selection.admit(state.selection) do
      :ok ->
        enqueue_turn(state, prompt)

      {:error, reason} ->
        {%{state | activity: {:failed, :selection, reason, reason}}, []}
    end
  end

  defp enqueue_turn(state, prompt) do
    turn = Turn.new(state.next_turn_id, prompt)

    state = remember_prompt(state, prompt)

    state =
      %{
        state
        | editor: Editor.clear(state.editor),
          scroll_offset: 0,
          messages: state.messages ++ [%{role: :user, content: turn.prompt}],
          activity: {:starting, {:turn, turn}},
          next_turn_id: state.next_turn_id + 1
      }
      |> recompute_completion()

    {state, [{:start_turn, turn.prompt}]}
  end

  defp changed(state, updates) do
    state = struct!(state, updates)
    {state, []}
  end

  defp unchanged(state), do: {state, []}

  defp replace_editor(state, editor) do
    state
    |> struct!(editor: editor)
    |> recompute_completion()
    |> unchanged()
  end

  defp edit(state, editor) do
    state
    |> struct!(editor: editor, history_index: nil, history_draft: nil)
    |> recompute_completion()
    |> unchanged()
  end

  defp editor_event(state, event) do
    {editor, messages} = Editor.update(state.editor, event)
    edited? = Enum.any?(messages, &match?({:changed, _value}, &1))
    effects = for {:copy, text} <- messages, do: {:copy, text}

    state =
      if edited? do
        %{state | editor: editor, history_index: nil, history_draft: nil}
      else
        %{state | editor: editor}
      end

    {recompute_completion(state), effects}
  end

  defp editor_mouse(state, event) do
    {columns, rows} = state.size
    width = max(columns - 2, 1)
    height = min(5, max(rows - 4, 1))
    prompt_y = rows - height

    if event.x >= 2 and event.y >= prompt_y do
      local = %{event | x: event.x - 2, y: event.y - prompt_y}
      {editor, messages} = Editor.mouse(state.editor, local, {width, height})
      effects = for {:copy, text} <- messages, do: {:copy, text}
      {%{state | editor: editor} |> recompute_completion(), effects}
    else
      {state, []}
    end
  end

  defp move_completion_or_editor(%__MODULE__{} = state, direction) do
    if completion_interactive?(state) and not review?(state),
      do: {%{state | completion: Autocomplete.move(state.completion, direction)}, []},
      else: move_editor_or_history(state, direction)
  end

  defp move_editor_or_history(state, :up), do: move_up(state)
  defp move_editor_or_history(state, :down), do: move_down(state)

  defp complete(%__MODULE__{} = state) do
    if completion_interactive?(state) and not review?(state) and
         is_binary(state.completion.completion) do
      context = state.completion.context

      state =
        state
        |> struct!(
          editor: Editor.replace(state.editor, state.completion.completion),
          history_index: nil,
          history_draft: nil
        )
        |> recompute_completion()

      completion =
        if context == :command and state.completion.context == :model,
          do: state.completion,
          else: %Autocomplete{}

      {%{state | completion: completion}, []}
    else
      {state, []}
    end
  end

  defp move_up(state) do
    editor = Editor.up(state.editor)

    if editor == state.editor,
      do: previous_history(state),
      else: state |> struct!(editor: editor) |> recompute_completion() |> unchanged()
  end

  defp move_down(state) do
    editor = Editor.down(state.editor)

    if editor == state.editor,
      do: next_history(state),
      else: state |> struct!(editor: editor) |> recompute_completion() |> unchanged()
  end

  defp previous_history(%__MODULE__{history: []} = state), do: {state, []}

  defp previous_history(%__MODULE__{history_index: nil} = state) do
    index = length(state.history) - 1

    state
    |> struct!(
      editor: state.history |> Enum.at(index) |> Editor.from_text(),
      history_index: index,
      history_draft: Editor.value(state.editor)
    )
    |> recompute_completion()
    |> unchanged()
  end

  defp previous_history(%__MODULE__{history_index: index} = state) do
    index = max(index - 1, 0)

    state
    |> struct!(editor: state.history |> Enum.at(index) |> Editor.from_text(), history_index: index)
    |> recompute_completion()
    |> unchanged()
  end

  defp next_history(%__MODULE__{history_index: nil} = state), do: {state, []}

  defp next_history(state) do
    index = state.history_index + 1

    if index < length(state.history) do
      state
      |> struct!(editor: state.history |> Enum.at(index) |> Editor.from_text(), history_index: index)
      |> recompute_completion()
      |> unchanged()
    else
      history_draft = if is_nil(state.history_draft), do: "", else: state.history_draft

      state
      |> struct!(editor: Editor.from_text(history_draft), history_index: nil, history_draft: nil)
      |> recompute_completion()
      |> unchanged()
    end
  end

  defp remember_prompt(state, prompt) do
    history = if List.last(state.history) == prompt, do: state.history, else: state.history ++ [prompt]
    %{state | history: retain(history, state.history_limit), history_index: nil, history_draft: nil}
  end

  defp scroll_page(%__MODULE__{size: {_columns, rows}}), do: max(rows - 4, 1)

  defp recompute_completion(%__MODULE__{} = state) do
    completion =
      if completion_capacity(state) > 0 do
        Autocomplete.derive(
          Editor.value(state.editor),
          Editor.cursor(state.editor),
          state.selection,
          state.completion.focused_identity
        )
      else
        %Autocomplete{}
      end

    %{state | completion: completion}
  end

  defp completion_capacity(%__MODULE__{size: {width, height}} = state)
       when width >= 12 and height >= 5 do
    prompt_limit = min(5, max(height - 4, 1))
    editor_height = Editor.frame(state.editor, max(width - 2, 1), prompt_limit).height

    height
    |> Kernel.-(3 + editor_height)
    |> max(0)
    |> min(@completion_row_limit)
  end

  defp completion_capacity(%__MODULE__{}), do: 0

  defp completion_visible?(%__MODULE__{} = state),
    do: completion_slice(state).rows != []

  defp completion_interactive?(%__MODULE__{} = state),
    do: completion_slice(state).interactive?

  defp review?(%__MODULE__{activity: {:review, _, _, _, _}}), do: true
  defp review?(%__MODULE__{}), do: false

  defp existing_escape(%__MODULE__{activity: activity} = state)
       when activity == :idle or elem(activity, 0) in [:starting, :failed],
       do: {state, [:exit]}

  defp existing_escape(%__MODULE__{} = state), do: {state, []}

  defp finish(state, session, content, next_activity, opts) do
    error = Activity.error(next_activity)
    content = finish_content(content, state.activity)
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
         next_turn_id: next_turn_id
     }, []}
  end

  defp finish_content(content, _activity) when is_binary(content) and byte_size(content) > 0, do: content
  defp finish_content(_content, activity), do: Activity.streaming(activity)

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
       when is_map(event) do
    review = if turn.reviews == [], do: %{}, else: hd(turn.reviews)
    turn = turn |> Turn.decide_review(review, decision) |> Turn.resume()

    {%{
       state
       | activity: {:review, request, turn, event, {:responding, decision}}
     }, [{:respond_review, decision, request, event, review}]}
  end

  defp respond_to_review(state, _decision), do: {state, []}

  defp started_activity(request, %Turn{} = turn) do
    case Enum.find(turn.reviews, &(Map.get(&1, :status) == :pending)) do
      nil -> {:active, request, turn, :streaming}
      _review -> {:review, request, turn, %{}, :awaiting}
    end
  end

  defp format_error(reason) do
    Error.message(reason)
  rescue
    _exception -> inspect(reason)
  end

  defp invalid_command_notice(state, message, details) do
    state
    |> notice(format_error(Error.validation_error(message, details)))
  end

  defp view_message(message) do
    role = message |> map_get(:role, :assistant) |> normalize_role()

    %{
      role: role,
      content: safe_message_content(message, role),
      tool_calls: message |> map_get(:tool_calls, []) |> safe_tool_calls(),
      operation: message |> map_get(:operation) |> safe_optional_text(),
      tool_call_id: message |> map_get(:tool_call_id) |> safe_optional_text()
    }
  end

  defp safe_message_content(_message, :tool), do: ""

  defp safe_message_content(message, _role) do
    message |> map_get(:content, "") |> SafeText.clean()
  end

  defp transcript_turns(messages, limit) do
    {turns, pending, _next_id} =
      Enum.reduce(messages, {[], nil, 0}, fn
        %{role: :user, content: content}, {turns, pending, id} ->
          turns = finish_pending(turns, pending)
          {turns, Turn.new(id, content), id + 1}

        %{role: :assistant, tool_calls: tool_calls}, {turns, %Turn{} = pending, id}
        when tool_calls != [] ->
          {turns, Turn.restore_tool_calls(pending, tool_calls), id}

        %{role: :tool} = message, {turns, %Turn{} = pending, id} ->
          {turns, Turn.restore_tool_result(pending, message), id}

        %{role: :assistant, content: content}, {turns, %Turn{} = pending, id} ->
          {turns ++ [Turn.finish(pending, :completed, content)], nil, id}

        _message, acc ->
          acc
      end)

    turns = finish_pending(turns, pending)
    retain(turns, limit)
  end

  defp finish_pending(turns, nil), do: turns
  defp finish_pending(turns, %Turn{} = pending), do: turns ++ [Turn.finish(pending, :completed, nil)]

  defp restore_history_outcomes(turns, history, limit) do
    records = closing_history_records(history)

    {turns, unmatched} =
      Enum.map_reduce(turns, records, fn turn, records ->
        case take_history_record(records, turn.prompt) do
          {nil, records} -> {turn, records}
          {record, records} -> {finish_from_history(turn, record), records}
        end
      end)

    restored =
      unmatched
      |> Enum.reject(&(&1.type == "prompt_succeeded"))
      |> Enum.with_index(length(turns))
      |> Enum.map(fn {record, id} ->
        id
        |> Turn.new(record.input || "")
        |> finish_from_history(record)
      end)

    retain(turns ++ restored, limit)
  end

  defp closing_history_records(history) do
    {records, _inputs} =
      Enum.reduce(history, {[], %{}}, fn event, {records, inputs} ->
        type = map_get(event, :type)
        queue_item_id = map_get(event, :queue_item_id)

        case type do
          "prompt_queued" ->
            input = event |> map_get(:payload, %{}) |> map_get(:input)
            {records, Map.put(inputs, queue_item_id, input)}

          type when type in ["prompt_succeeded", "prompt_failed", "prompt_cancelled", "prompt_interrupted"] ->
            record = %{
              type: type,
              input: Map.get(inputs, queue_item_id),
              request_id: map_get(event, :request_id),
              payload: map_get(event, :payload, %{})
            }

            {records ++ [record], inputs}

          _other ->
            {records, inputs}
        end
      end)

    records
  end

  defp take_history_record(records, prompt) do
    case Enum.find_index(records, &(&1.input == prompt)) do
      nil -> {nil, records}
      index -> List.pop_at(records, index)
    end
  end

  defp finish_from_history(turn, record) do
    turn = Turn.put_request(turn, %{request_id: record.request_id})
    {outcome, error} = history_outcome(record.type, record.payload)
    Turn.finish(turn, outcome, history_content(record, turn.assistant), error: error)
  end

  defp history_content(%{type: "prompt_succeeded", payload: payload}, "") do
    case map_get(payload, :result) do
      result when is_binary(result) -> result
      result when is_map(result) -> map_get(result, :content, "")
      _result -> ""
    end
  end

  defp history_content(_record, assistant), do: assistant

  defp history_outcome("prompt_succeeded", _payload), do: {:completed, nil}
  defp history_outcome("prompt_failed", payload), do: {:failed, payload |> map_get(:error) |> history_error()}
  defp history_outcome("prompt_cancelled", payload), do: {:cancelled, payload |> map_get(:error) |> history_error()}

  defp history_outcome("prompt_interrupted", payload),
    do: {:interrupted, payload |> map_get(:error, map_get(payload, :reason)) |> history_error()}

  defp history_error(nil), do: nil
  defp history_error(reason), do: format_error(reason)

  defp view_activity(%SessionView{active: nil, status: :unavailable, error: error}, _id),
    do: {{:failed, :turn, error, format_error(error)}, []}

  defp view_activity(%SessionView{active: nil, status: :reconciling}, _id),
    do: {{:failed, :startup, :thread_reconciling, "Thread recovery is in progress."}, []}

  defp view_activity(%SessionView{active: nil}, _id), do: {:idle, []}

  defp view_activity(%SessionView{} = view, id) do
    request = %{
      queue_item_id: view.active["queue_item_id"],
      request_id: view.active["request_id"]
    }

    turn =
      id
      |> Turn.new(active_input(view.active))
      |> Turn.put_request(request)
      |> Turn.apply_stream(view.partial)

    if view.status == :review and is_map(view.review) do
      review = normalize_view_review(view.review)
      turn = %{turn | reviews: [review], status: :review}
      {{:review, request, turn, view.review, :awaiting}, [review]}
    else
      phase = if(view.status == :finishing, do: :finishing, else: :streaming)
      {{:active, request, turn, phase}, []}
    end
  end

  defp active_input(active) do
    case active["input"] do
      input when is_binary(input) -> input
      _other -> ""
    end
  end

  defp normalize_view_review(review) do
    %{
      id: map_get(review, :id),
      operation: map_get(review, :operation),
      reason: map_get(review, :reason),
      arguments: map_get(review, :arguments, %{}),
      status: :pending
    }
  end

  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:tool, "tool"], do: :tool
  defp normalize_role(role) when role in [:system, "system"], do: :system
  defp normalize_role(_role), do: :system

  defp safe_tool_calls(calls) when is_list(calls) do
    calls
    |> Enum.flat_map(fn
      call when is_map(call) ->
        name = map_get(call, :name, map_get(call, :operation))

        if is_binary(name) and name != "" do
          [
            %{
              name: SafeText.summary(name),
              provider_call_id: call |> map_get(:provider_call_id, map_get(call, :id)) |> safe_optional_text()
            }
          ]
        else
          []
        end

      _call ->
        []
    end)
  end

  defp safe_tool_calls(_calls), do: []

  defp safe_optional_text(value) when is_binary(value), do: SafeText.summary(value)
  defp safe_optional_text(_value), do: nil

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(_map, _key, default), do: default

  defp retain(values, limit) when length(values) > limit, do: Enum.take(values, -limit)
  defp retain(values, _limit), do: values

  defp positive_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp notice(state, message, selection \\ nil) do
    notices = retain(state.command_notices ++ [SafeText.clean(message)], @command_notice_limit)

    state = %{
      state
      | selection: selection || state.selection,
        editor: Editor.clear(state.editor),
        command_notices: notices,
        scroll_offset: 0
    }

    {recompute_completion(state), []}
  end

  defp restore_model_selection(selection, nil), do: selection

  defp restore_model_selection(selection, model) do
    identity = Map.get(model, "identity", Map.get(model, :identity))
    tier = Map.get(model, "tier", Map.get(model, :tier))
    locked? = Map.get(model, "locked", Map.get(model, :locked, false))
    tier = normalize_model_tier(tier)

    selection
    |> Map.put(:model, identity)
    |> Map.put(:model_tier, tier)
    |> Map.put(:model_locked?, locked?)
  end

  defp normalize_model_tier("supported"), do: :supported
  defp normalize_model_tier("beta"), do: :beta
  defp normalize_model_tier("available"), do: :available
  defp normalize_model_tier("unsupported"), do: :unsupported
  defp normalize_model_tier(tier) when is_atom(tier), do: tier
  defp normalize_model_tier(_tier), do: nil
end
