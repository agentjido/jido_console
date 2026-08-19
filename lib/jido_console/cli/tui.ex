defmodule Jido.Console.Tui do
  @moduledoc "Full-screen Jido chat loop."

  alias Jido.Console.Tui.{Effects, Selection, Shutdown, State, View, Workers}
  alias Jido.Console.Coding.Setup
  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.TUI, as: SessionTUI
  alias Jido.Console.Session.Identity
  alias Jido.Console.Terminal

  @frame_interval_ms 33
  @shutdown_timeout_ms 250

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    opts = resolve_initial_selection(opts)
    runtime = Keyword.get(opts, :runtime, Jido.Console.Runtime.Jidoka)
    agent = Keyword.get(opts, :agent, Jido.Console.DefaultAgent)

    with {:ok, terminal} <- open_terminal(opts) do
      try do
        run_terminal(terminal, runtime, agent, opts)
      after
        Terminal.close(terminal)
      end
    end
  end

  defp resolve_initial_selection(opts) do
    selection = Selection.init(opts)

    opts
    |> Keyword.put(:catalog_entries, selection.catalog_entries)
    |> Keyword.put(:model, selection.model)
    |> Keyword.put(:coding_profile, selection.profile_id)
  end

  defp run_terminal(terminal, runtime, agent, opts) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      run_terminal_loop(terminal, runtime, agent, opts)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp run_terminal_loop(terminal, runtime, agent, opts) do
    state =
      State.new(
        nil,
        terminal.size,
        [
          prepare_prompt: true,
          activity: {:starting, {:runtime, :empty}},
          model: Keyword.get(opts, :model),
          coding_profile: Keyword.get(opts, :coding_profile)
        ] ++ Keyword.take(opts, [:catalog_entries])
      )

    with {:ok, state} <- draw_now(state, terminal) do
      start_terminal(terminal, runtime, agent, state, opts)
    end
  end

  defp start_terminal(terminal, runtime, agent, state, opts) do
    with :ok <- safe_start_application(opts),
         {:ok, %{handle: session_client, events: events}} <- attach_session_client(opts) do
      runtime_info = runtime_info(session_client)

      state =
        state
        |> Map.put(:session_client, session_client)
        |> State.restore_events(events, Map.get(runtime_info, :active_request))

      case register_interactive_process(opts) do
        {:ok, _record} ->
          run_attached_terminal(terminal, runtime, agent, session_client, state, opts)

        {:error, reason} ->
          detach_session_client(session_client)
          run_startup_failure(state, terminal, reason)
      end
    else
      {:error, reason} -> run_startup_failure(state, terminal, reason)
    end
  end

  defp runtime_info(session_client) do
    case Client.runtime_info(session_client) do
      {:ok, info} -> info
      {:error, _reason} -> %{}
    end
  end

  defp run_attached_terminal(terminal, runtime, agent, session_client, state, opts) do
    try do
      with {:ok, state} <- draw_now(state, terminal) do
        run_runtime_loop(terminal, runtime, agent, session_client, state, opts)
      end
    after
      detach_session_client(session_client)
      stop_interactive_process(opts)
    end
  end

  defp run_runtime_loop(terminal, runtime, agent, session_client, state, opts) do
    owner = self()

    {startup_pid, startup_ref} =
      spawn_monitor(fn -> runtime_owner(owner, runtime, agent, session_client, opts) end)

    try do
      {result, state, workers} =
        loop(state, terminal, runtime, opts, %{pid: startup_pid, ref: startup_ref}, %{})

      Shutdown.run(state, workers, runtime, opts)
      result
    after
      stop_runtime_owner(startup_pid, startup_ref, shutdown_timeout(opts))
    end
  end

  defp safe_start_application(opts) do
    startup = Keyword.get(opts, :application_startup, fn -> :ok end)

    if is_function(startup, 0) do
      startup.()
    else
      {:error, :invalid_application_startup}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp register_interactive_process(opts) do
    register = Keyword.get(opts, :process_register, &Jido.Console.Process.register/3)

    case register.(:interactive, self(), process_opts(opts)) do
      {:ok, _record} = result -> result
      {:error, reason} -> {:error, {:process_register_failed, reason}}
      other -> {:error, {:process_register_failed, other}}
    end
  rescue
    exception -> {:error, {:process_register_failed, exception}}
  catch
    kind, reason -> {:error, {:process_register_failed, {kind, reason}}}
  end

  defp stop_interactive_process(opts) do
    stop = Keyword.get(opts, :process_stop, &Jido.Console.Process.stop/2)
    _result = stop.("interactive", process_opts(opts))
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp run_startup_failure(state, terminal, reason) do
    {state, []} = State.update(state, {:runtime_failed, reason})

    with {:ok, state} <- draw_now(state, terminal) do
      startup_failure_loop(state, terminal, reason)
    end
  end

  defp startup_failure_loop(state, terminal, reason) do
    receive do
      {:jido_terminal, ref, event} when ref == terminal.ref ->
        {state, effects} = State.update(state, {:terminal, event})

        if :exit in effects do
          {:error, reason}
        else
          case draw_now(state, terminal) do
            {:ok, state} -> startup_failure_loop(state, terminal, reason)
            {:error, draw_reason} -> {:error, draw_reason}
          end
        end

      _message ->
        startup_failure_loop(state, terminal, reason)
    end
  end

  defp draw_now(%State{dirty?: true} = state, terminal) do
    with :ok <- Terminal.draw(terminal, View.render(state)) do
      {state, []} = State.update(state, :rendered)
      {:ok, state}
    end
  end

  defp draw_now(state, _terminal), do: {:ok, state}

  defp runtime_owner(owner, runtime, agent, session_client, opts) do
    owner_monitor = Process.monitor(owner)
    result = safe_start_runtime(runtime, agent, session_client, opts)

    if runtime_owner_stopping?(owner_monitor) do
      :ok
    else
      send(owner, {:jido_runtime_startup, self(), result})

      case result do
        {:ok, startup} -> runtime_owner_loop(owner_monitor, runtime, agent, session_client, startup)
        {:error, _reason} -> :ok
      end
    end
  end

  defp runtime_owner_stopping?(owner_monitor) do
    receive do
      {:close, _owner} -> true
      {:DOWN, ^owner_monitor, :process, _owner, _reason} -> true
    after
      0 -> false
    end
  end

  defp safe_start_runtime(runtime, agent, session_client, opts) do
    startup = Keyword.get(opts, :runtime_startup, fn -> :ok end)

    if is_function(startup, 0) do
      with :ok <- startup.(),
           {:ok, info} <- Client.runtime_info(session_client) do
        select_runtime_start(info, runtime, agent, session_client, opts)
      end
    else
      {:error, :invalid_runtime_startup}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp select_runtime_start(
         %{configured?: true, client_setup: coding},
         runtime,
         agent,
         session_client,
         opts
       )
       when not is_nil(coding) do
    if Keyword.get(opts, :force_runtime_configure, false) do
      prepare_runtime_start(runtime, agent, session_client, opts)
    else
      {:ok, %{coding: coding, opts: ready_opts(opts, coding), session: session_client}}
    end
  end

  defp select_runtime_start(_info, runtime, agent, session_client, opts),
    do: prepare_runtime_start(runtime, agent, session_client, opts)

  defp prepare_runtime_start(runtime, agent, session_client, opts) do
    with {:ok, coding} <- Setup.prepare(agent, opts) do
      start_runtime_session(runtime, agent, session_client, coding, opts)
    end
  end

  defp start_runtime_session(runtime, agent, session_client, coding, opts) do
    session_opts =
      opts
      |> Keyword.get(:session_opts, [])
      |> Keyword.put(:extension_setup, coding.extension_setup)
      |> Keyword.put(:agent_spec_override, coding.spec)
      |> Keyword.put(:local_resources, coding.local_resources)
      |> Keyword.put(:owned_resource, coding)
      |> Keyword.put(:resource_closer, {Setup, :close, []})
      |> Keyword.put(:client_setup, Setup.client_setup(coding))

    case Client.configure_runtime(session_client, runtime, agent, session_opts) do
      :ok ->
        {:ok,
         %{
           coding: coding,
           opts: ready_opts(opts, coding),
           session: session_client
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      Setup.close(coding)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      Setup.close(coding)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp ready_opts(opts, coding) do
    opts
    |> Keyword.update(:turn_opts, coding.turn_opts, &Keyword.merge(coding.turn_opts, &1))
    |> Keyword.put_new(:await_opts,
      timeout: coding.await_timeout_ms,
      cancel_on_timeout: false
    )
    |> Keyword.put(:coding_setup_resolved, coding)
  end

  defp runtime_owner_loop(owner_monitor, runtime, agent, session_client, startup) do
    receive do
      {:reconfigure, caller, selection} ->
        result = reconfigure_runtime(runtime, agent, session_client, startup, selection)
        send(caller, {:jido_runtime_reconfigure, self(), result})

        case result do
          {:ok, next} -> runtime_owner_loop(owner_monitor, runtime, agent, session_client, next)
          {:error, _reason} -> runtime_owner_loop(owner_monitor, runtime, agent, session_client, startup)
        end

      {:close, _owner} ->
        :ok

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        :ok
    end
  end

  defp reconfigure_runtime(runtime, agent, session_client, startup, selection) do
    opts =
      startup.opts
      |> Keyword.put(:model, selection.model)
      |> Keyword.put(:coding_profile, selection.profile_id)
      |> Keyword.drop([:turn_opts, :await_opts, :coding_setup_resolved])
      |> Keyword.put(:force_runtime_configure, true)

    case safe_start_runtime(runtime, agent, session_client, opts) do
      {:ok, next} ->
        {:ok, next}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_runtime_owner(startup_pid, startup_ref, timeout_ms) do
    if Process.alive?(startup_pid) do
      send(startup_pid, {:close, self()})

      unless await_process_down(startup_pid, startup_ref, timeout_ms) do
        Process.exit(startup_pid, :kill)
        _stopped? = await_process_down(startup_pid, startup_ref, timeout_ms)
      end
    end

    Process.demonitor(startup_ref, [:flush])
    :ok
  end

  defp open_terminal(opts) do
    Terminal.open(
      owner: self(),
      adapter: Keyword.get(opts, :terminal_adapter, Jido.Console.Terminal.OTP),
      adapter_opts: Keyword.get(opts, :terminal_adapter_opts, [])
    )
  end

  defp loop(
         state,
         terminal,
         runtime,
         opts,
         %{pid: startup_pid, ref: startup_ref} = startup,
         workers
       ) do
    receive do
      {:jido_terminal, ref, event} when ref == terminal.ref ->
        continue(state, {:terminal, event}, terminal, runtime, opts, startup, workers)

      {:jido_console_session, attachment_id, {:event, event}} ->
        handle_session_event(state, attachment_id, event, terminal, runtime, opts, startup, workers)

      {:jido_tui_effect_result, worker_pid, outcome} ->
        handle_effect_result(
          state,
          worker_pid,
          outcome,
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      {:jido_runtime_startup, ^startup_pid, {:ok, startup}} ->
        continue(
          state,
          {:runtime_ready, startup.session, startup.coding.instructions},
          terminal,
          runtime,
          with_runtime_owner(startup.opts, startup_pid),
          %{pid: startup_pid, ref: startup_ref},
          workers
        )

      {:jido_runtime_startup, ^startup_pid, {:error, reason}} ->
        continue(
          state,
          {:runtime_failed, reason},
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      {:DOWN, ^startup_ref, :process, ^startup_pid, :normal} ->
        loop(state, terminal, runtime, opts, startup, workers)

      {:DOWN, ^startup_ref, :process, ^startup_pid, reason} ->
        continue(
          state,
          {:runtime_failed, {:runtime_owner_failed, reason}},
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      {:DOWN, worker_ref, :process, worker_pid, reason} ->
        handle_worker_down(
          state,
          worker_pid,
          worker_ref,
          reason,
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      :render_frame ->
        case Terminal.draw(terminal, View.render(state)) do
          :ok ->
            {state, []} = State.update(state, :rendered)
            loop(state, terminal, runtime, opts, startup, workers)

          {:error, reason} ->
            {{:error, reason}, state, workers}
        end

      _message ->
        loop(state, terminal, runtime, opts, startup, workers)
    end
  end

  defp continue(state, event, terminal, runtime, opts, startup, workers) do
    {state, effects} = State.update(state, event)
    continue_transition(state, effects, terminal, runtime, opts, startup, workers)
  end

  defp continue_transition(state, effects, terminal, runtime, opts, startup, workers) do
    case paint_before_effects(state, effects, terminal) do
      {:ok, state} ->
        case Effects.dispatch(state, effects, runtime, opts, workers) do
          {:continue, workers} ->
            state = schedule_render(state)
            loop(state, terminal, runtime, opts, startup, workers)

          {:exit, workers} ->
            {exit_result(state), state, workers}
        end

      {:error, reason} ->
        {{:error, reason}, state, workers}
    end
  end

  defp exit_result(state) do
    case State.startup_failure(state) do
      {:ok, reason} -> {:error, reason}
      :none -> :ok
    end
  end

  defp paint_before_effects(state, [], _terminal), do: {:ok, state}
  defp paint_before_effects(state, [:exit | _effects], _terminal), do: {:ok, state}

  defp paint_before_effects(%State{dirty?: true} = state, _effects, terminal) do
    with :ok <- Terminal.draw(terminal, View.render(state)) do
      {state, []} = State.update(state, :rendered)
      {:ok, state}
    end
  end

  defp paint_before_effects(state, _effects, _terminal), do: {:ok, state}

  defp handle_effect_result(
         state,
         worker_pid,
         outcome,
         terminal,
         runtime,
         opts,
         startup,
         workers
       ) do
    case Workers.take_completion(workers, worker_pid) do
      {:ok, worker, workers} ->
        handle_completed_effect(
          state,
          worker,
          outcome,
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      :error ->
        loop(state, terminal, runtime, opts, startup, workers)
    end
  end

  defp handle_completed_effect(
         state,
         worker,
         outcome,
         terminal,
         runtime,
         opts,
         startup,
         workers
       ) do
    case Effects.complete(worker, outcome) do
      {:event, event} ->
        continue(state, event, terminal, runtime, opts, startup, workers)

      {:reconfigured, next} ->
        continue(
          state,
          {:runtime_ready, next.session, next.coding.instructions},
          terminal,
          runtime,
          with_runtime_owner(next.opts, startup.pid),
          startup,
          workers
        )

      :ignore ->
        loop(state, terminal, runtime, opts, startup, workers)
    end
  end

  defp handle_worker_down(
         state,
         worker_pid,
         worker_ref,
         reason,
         terminal,
         runtime,
         opts,
         startup,
         workers
       ) do
    case Workers.take_down(workers, worker_pid, worker_ref) do
      {:ok, worker, workers} ->
        handle_completed_effect(
          state,
          worker,
          {:crash, {:effect_worker_down, reason}},
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      :error ->
        loop(state, terminal, runtime, opts, startup, workers)
    end
  end

  defp schedule_render(%State{dirty?: true, render_scheduled?: false} = state) do
    Process.send_after(self(), :render_frame, @frame_interval_ms)
    {state, []} = State.update(state, :render_scheduled)
    state
  end

  defp schedule_render(state), do: state

  defp await_process_down(pid, ref, timeout_ms) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      timeout_ms -> not Process.alive?(pid)
    end
  end

  defp shutdown_timeout(opts), do: option_timeout(opts, :shutdown_timeout_ms, @shutdown_timeout_ms)

  defp option_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp handle_session_event(
         %State{session_client: handle} = state,
         attachment_id,
         event,
         terminal,
         runtime,
         opts,
         startup,
         workers
       ) do
    if Client.Handle.identity(handle).attachment_id == attachment_id do
      case SessionTUI.apply_event(handle, state, event) do
        {:ok, state} -> loop(schedule_render(state), terminal, runtime, opts, startup, workers)
        {:error, _reason, state} -> loop(state, terminal, runtime, opts, startup, workers)
      end
    else
      loop(state, terminal, runtime, opts, startup, workers)
    end
  end

  defp attach_session_client(opts) do
    supervisor_opts = Keyword.take(opts, [:name, :registry, :tasks, :sessions])
    _ = Jido.Console.Session.Supervisor.ensure_started(supervisor_opts)
    session_id = Keyword.get_lazy(opts, :session_id, fn -> Identity.new!(:session).id end)

    client_opts = Keyword.take(opts, [:registry, :supervisor, :tasks, :catalog, :descriptor])

    case SessionTUI.attach(session_id, client_opts) do
      {:ok, attached} -> {:ok, attached}
      {:error, reason} -> {:error, {:session_attach_failed, reason}}
    end
  rescue
    exception -> {:error, {:session_attach_failed, exception}}
  end

  defp detach_session_client(handle) do
    Client.detach_async(handle)
  catch
    :exit, _reason -> :ok
  end

  defp process_opts(opts), do: Keyword.take(opts, [:name, :jido_home])

  defp with_runtime_owner(opts, pid) when is_pid(pid), do: Keyword.put(opts, :runtime_owner, pid)
end
