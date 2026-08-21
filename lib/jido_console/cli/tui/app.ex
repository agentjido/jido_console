defmodule Jido.Console.Tui.App do
  @moduledoc "TermUI root for one attached Console thread."

  use TermUI.Elm

  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.TUI, as: SessionTUI
  alias Jido.Console.Tui.{Effects, Shutdown, State, View, Workers}
  alias TermUI.Component.RenderNode
  alias TermUI.Event
  alias TermUI.Renderer.{Cell, DisplayWidth}

  @impl TermUI.Elm
  def init(opts) do
    tui_opts = Keyword.fetch!(opts, :tui_opts)
    {tui, registered?} = boot(tui_opts, Keyword.fetch!(opts, :dimensions))

    %{
      tui: tui,
      opts: tui_opts,
      result_owner: Keyword.fetch!(opts, :result_owner),
      result_ref: Keyword.fetch!(opts, :result_ref),
      workers: %{},
      registered?: registered?,
      closing?: false,
      result_sent?: false
    }
  end

  @impl TermUI.Elm
  def event_to_msg(_event, %{closing?: true}), do: :ignore

  def event_to_msg(%Event.Resize{width: width, height: height}, _state),
    do: {:msg, {:terminal, {:resize, width, height}}}

  def event_to_msg(%Event.Paste{content: content}, _state),
    do: {:msg, {:terminal, {:paste, content}}}

  def event_to_msg(%Event.Key{key: "c", modifiers: modifiers}, _state)
      when modifiers == [:ctrl],
      do: {:msg, {:terminal, {:key, :ctrl_c}}}

  def event_to_msg(%Event.Key{key: key, modifiers: modifiers}, _state)
      when key in ["j", :enter] and modifiers == [:ctrl],
      do: {:msg, {:terminal, {:key, :newline}}}

  def event_to_msg(%Event.Key{key: key}, _state)
      when key in [:enter, :backspace, :left, :right, :up, :down, :page_up, :page_down, :escape],
      do: {:msg, {:terminal, {:key, key}}}

  def event_to_msg(%Event.Key{char: char, modifiers: []}, _state)
      when is_binary(char) and char != "",
      do: {:msg, {:terminal, {:text, char}}}

  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update(:stop, state), do: {state, [:quit]}

  def update({:terminal, event}, state) do
    state.tui
    |> State.update({:terminal, event})
    |> dispatch(state)
  end

  def update(message, state) do
    state.tui
    |> State.update(message)
    |> dispatch(state)
  end

  @impl TermUI.Elm
  def handle_info({:jido_console_view, attachment_ref, session_view}, state) do
    with handle when not is_nil(handle) <- state.tui.session_client,
         true <- Client.attachment_ref(handle) == attachment_ref,
         {:ok, tui} <- SessionTUI.apply_view(handle, state.tui, session_view) do
      {%{state | tui: tui}, []}
    else
      _other -> :noreply
    end
  end

  def handle_info({:jido_tui_effect_result, worker_pid, outcome}, state) do
    case Workers.take_completion(state.workers, worker_pid) do
      {:ok, worker, workers} -> complete_effect(worker, outcome, %{state | workers: workers})
      :error -> :noreply
    end
  end

  def handle_info({:DOWN, worker_ref, :process, worker_pid, reason}, state) do
    case Workers.take_down(state.workers, worker_pid, worker_ref) do
      {:ok, worker, workers} ->
        complete_effect(worker, {:crash, {:effect_worker_down, reason}}, %{state | workers: workers})

      :error ->
        :noreply
    end
  end

  def handle_info(_message, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    state.tui
    |> View.render()
    |> frame_node()
  end

  @impl TermUI.Elm
  def terminate(_reason, state) do
    safe_cleanup(fn -> Shutdown.run(state.tui, state.workers, Client, state.opts) end)
    safe_cleanup(fn -> detach(state.tui.session_client) end)
    safe_cleanup(fn -> stop_if_registered(state.registered?, state.opts) end)

    unless state.result_sent? do
      send(state.result_owner, {:jido_tui_result, state.result_ref, exit_result(state.tui)})
    end

    :ok
  end

  defp complete_effect(worker, outcome, state) do
    case Effects.complete(worker, outcome) do
      {:event, event} -> update(event, state)
      :ignore -> :noreply
    end
  end

  defp dispatch({tui, effects}, state) do
    state = %{state | tui: tui}

    case Effects.dispatch(tui, effects, Client, state.opts, state.workers) do
      {:continue, workers} ->
        {%{state | workers: workers}, []}

      {:exit, workers} ->
        finish(%{state | workers: workers})
    end
  end

  defp finish(%{closing?: true} = state), do: {state, []}

  defp finish(state) do
    message = {:jido_tui_result, state.result_ref, exit_result(state.tui)}

    {%{state | closing?: true, result_sent?: true}, [{:send, state.result_owner, message}, {:timer, 0, :stop}]}
  end

  defp boot(opts, size) do
    with :ok <- application_startup(opts),
         {:ok, %{handle: handle, view: session_view}} <- attach(opts) do
      tui = session_state(handle, session_view, size, opts)

      case register_interactive(opts) do
        {:ok, _record} -> {tui, true}
        {:error, reason} -> {failure_state(reason, size, opts, tui), false}
      end
    else
      {:error, reason} -> {failure_state(reason, size, opts), false}
    end
  end

  defp session_state(handle, session_view, size, opts) do
    State.new(session_view, size,
      session_client: handle,
      activity: :idle,
      model: Keyword.get(opts, :model),
      coding_profile: Keyword.get(opts, :coding_profile),
      catalog_entries: Keyword.get(opts, :catalog_entries, [])
    )
    |> State.restore_view(session_view)
  end

  defp failure_state(reason, size, opts, state \\ nil) do
    case state do
      %State{} ->
        %{state | activity: {:failed, :startup, reason, Jido.Console.Error.message(reason)}}

      nil ->
        State.new(nil, size,
          activity: {:failed, :startup, reason, Jido.Console.Error.message(reason)},
          model: Keyword.get(opts, :model),
          coding_profile: Keyword.get(opts, :coding_profile),
          catalog_entries: Keyword.get(opts, :catalog_entries, [])
        )
    end
  end

  defp attach(opts) do
    supervisor_opts = Keyword.take(opts, [:name, :registry, :tasks, :sessions])
    _ = Jido.Console.Session.Supervisor.ensure_started(supervisor_opts)
    thread_id = Keyword.get_lazy(opts, :session_id, fn -> Jidoka.Id.generate!("thread") end)

    owner_opts =
      opts
      |> Keyword.put(
        :supervisor,
        Keyword.get(opts, :sessions, Keyword.get(opts, :supervisor, Jido.Console.Session.DynamicSupervisor))
      )
      |> Keyword.put(:agent, Keyword.get(opts, :agent, Jido.Console.DefaultAgent))

    case SessionTUI.attach(thread_id, owner_opts) do
      {:ok, attached} -> {:ok, attached}
      {:error, reason} -> {:error, {:session_attach_failed, reason}}
    end
  rescue
    exception -> {:error, {:session_attach_failed, exception}}
  end

  defp application_startup(opts) do
    case Keyword.get(opts, :application_startup, fn -> :ok end) do
      startup when is_function(startup, 0) -> startup.()
      _startup -> {:error, :invalid_application_startup}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp register_interactive(opts) do
    register = Keyword.get(opts, :process_register, &Jido.Console.Process.register/3)

    case register.(:interactive, self(), process_opts(opts)) do
      {:ok, _record} = result -> result
      {:error, reason} -> {:error, {:process_register_failed, reason}}
      other -> {:error, {:process_register_failed, other}}
    end
  end

  defp stop_interactive(opts) do
    stop = Keyword.get(opts, :process_stop, &Jido.Console.Process.stop/2)
    _ = stop.("interactive", process_opts(opts))
    :ok
  end

  defp detach(nil), do: :ok
  defp detach(client), do: SessionTUI.detach(client)

  defp stop_if_registered(false, _opts), do: :ok
  defp stop_if_registered(true, opts), do: stop_interactive(opts)

  defp safe_cleanup(fun) do
    fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp exit_result(tui) do
    case State.startup_failure(tui) do
      {:ok, reason} -> {:error, reason}
      :none -> :ok
    end
  end

  defp process_opts(opts), do: Keyword.take(opts, [:name, :jido_home])

  defp frame_node(frame) do
    cells =
      frame.rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, y} -> row_cells(row, y, frame.cursor) end)

    RenderNode.cells(cells, width: frame.width, height: frame.height)
  end

  defp row_cells(row, y, cursor) do
    {cells, _x} =
      row
      |> String.graphemes()
      |> Enum.reduce({[], 0}, fn grapheme, {cells, x} ->
        width = max(DisplayWidth.width(grapheme), 1)
        attrs = if cursor_at?(cursor, x, y, width), do: [:reverse], else: []
        cell = Cell.new(grapheme, attrs: attrs)
        positioned = %{x: x, y: y, cell: cell}

        cells =
          cond do
            grapheme == " " and attrs == [] ->
              cells

            width == 2 ->
              [%{x: x + 1, y: y, cell: Cell.wide_placeholder(cell)}, positioned | cells]

            true ->
              [positioned | cells]
          end

        {cells, x + width}
      end)

    Enum.reverse(cells)
  end

  defp cursor_at?(nil, _x, _y, _width), do: false

  defp cursor_at?({column, row}, x, y, width) do
    row == y + 1 and column - 1 >= x and column - 1 < x + width
  end
end
