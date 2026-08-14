defmodule Jido.Cli.Tui do
  @moduledoc "Full-screen Jido chat loop."

  alias Jido.Cli.Tui.{Effects, Shutdown, State, View, Workers}
  alias Jido.Cli.Coding.Setup
  alias Jido.Cli.Terminal

  @frame_interval_ms 33
  @shutdown_timeout_ms 250
  @resource_close_timeout_ms 250

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    runtime = Keyword.get(opts, :runtime, Jido.Cli.Runtime.Jidoka)
    agent = Keyword.get(opts, :agent, Jido.Cli.DefaultAgent)

    with {:ok, terminal} <- open_terminal(opts) do
      try do
        run_terminal(terminal, runtime, agent, opts)
      after
        Terminal.close(terminal)
      end
    end
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
      State.new(nil, terminal.size,
        prepare_prompt: true,
        runtime_status: :starting
      )

    with :ok <- Terminal.draw(terminal, View.render(state)) do
      {state, []} = State.update(state, :rendered)
      owner = self()

      {startup_pid, startup_ref} =
        spawn_monitor(fn -> runtime_owner(owner, runtime, agent, opts) end)

      try do
        {result, state, workers} =
          loop(state, terminal, runtime, opts, %{pid: startup_pid, ref: startup_ref}, %{})

        Shutdown.run(state, workers, runtime, opts)
        result
      after
        stop_runtime_owner(startup_pid, startup_ref, shutdown_timeout(opts))
      end
    end
  end

  defp runtime_owner(owner, runtime, agent, opts) do
    owner_monitor = Process.monitor(owner)
    result = safe_start_runtime(runtime, agent, opts)

    if runtime_owner_stopping?(owner_monitor) do
      close_startup_result(runtime, result)
    else
      send(owner, {:jido_runtime_startup, self(), result})

      case result do
        {:ok, startup} -> runtime_owner_loop(owner_monitor, runtime, startup)
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

  defp safe_start_runtime(runtime, agent, opts) do
    startup = Keyword.get(opts, :runtime_startup, fn -> :ok end)

    if is_function(startup, 0) do
      with :ok <- startup.(),
           {:ok, coding} <- Setup.prepare(agent, opts) do
        start_runtime_session(runtime, agent, coding, opts)
      end
    else
      {:error, :invalid_runtime_startup}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_runtime_session(runtime, agent, coding, opts) do
    session_opts =
      opts
      |> Keyword.get(:session_opts, [])
      |> Keyword.put(:extension_setup, coding.extension_setup)
      |> Keyword.put(:agent_spec_override, coding.spec)
      |> Keyword.put(:local_resources, coding.local_resources)

    case runtime.start_session(agent, session_opts) do
      {:ok, session} ->
        {:ok,
         %{
           coding: coding,
           opts: ready_opts(opts, coding),
           session: session
         }}

      {:error, reason} ->
        Setup.close(coding)
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

  defp runtime_owner_loop(owner_monitor, runtime, startup) do
    receive do
      {:close, _owner} ->
        close_startup_result(runtime, {:ok, startup})

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        close_startup_result(runtime, {:ok, startup})
    end
  end

  defp close_startup_result(runtime, {:ok, startup}) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      close_resources(runtime, startup)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp close_startup_result(_runtime, {:error, _reason}), do: :ok

  defp close_resources(runtime, startup) do
    closers =
      [
        fn -> close_runtime_session(runtime, startup.session) end,
        fn -> Setup.close(startup.coding) end
      ]
      |> Map.new(fn closer ->
        {pid, ref} =
          :erlang.spawn_opt(
            fn -> safe_close(closer) end,
            [:link, :monitor]
          )

        {pid, ref}
      end)

    remaining = await_resource_closers(closers, System.monotonic_time(:millisecond) + @resource_close_timeout_ms)

    Enum.each(remaining, fn {pid, _ref} ->
      Process.unlink(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    _remaining = await_resource_closers(remaining, System.monotonic_time(:millisecond) + 100)
    :ok
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

  defp close_runtime_session(runtime, session) do
    if function_exported?(runtime, :close_session, 1), do: runtime.close_session(session), else: :ok
  end

  defp safe_close(fun) do
    _result = fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp await_resource_closers(closers, _deadline) when map_size(closers) == 0, do: closers

  defp await_resource_closers(closers, deadline) do
    receive do
      {:DOWN, ref, :process, pid, _reason} when is_map_key(closers, pid) ->
        closers = if Map.get(closers, pid) == ref, do: Map.delete(closers, pid), else: closers
        await_resource_closers(closers, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> closers
    end
  end

  defp open_terminal(opts) do
    Terminal.open(
      owner: self(),
      adapter: Keyword.get(opts, :terminal_adapter, Jido.Cli.Terminal.OTP),
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

      {:jidoka_turn_event, event} ->
        continue(state, {:jidoka, event}, terminal, runtime, opts, startup, workers)

      {:jido_turn_result, request, result} ->
        continue(
          state,
          {:turn_result, request, result},
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

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
          startup.opts,
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

  defp exit_result(%State{runtime_status: :failed, startup_error: reason}), do: {:error, reason}
  defp exit_result(_state), do: :ok

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
    case Workers.pop(workers, worker_pid) do
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

      {:start_turn, relay_pid, {:turn_started, request}} ->
        {state, effects} = State.update(state, {:turn_started, request})
        workers = Workers.activate_relay(workers, relay_pid, request)
        continue_transition(state, effects, terminal, runtime, opts, startup, workers)

      {:start_turn, relay_pid, event} ->
        workers = Workers.stop(workers, relay_pid)
        continue(state, event, terminal, runtime, opts, startup, workers)

      {:review_result, relay_pid, result} ->
        workers = Workers.stop(workers, relay_pid)
        continue(state, {:turn_result, result}, terminal, runtime, opts, startup, workers)

      {:request_result, request, result} ->
        finish_request_effect(
          state,
          request,
          result,
          terminal,
          runtime,
          opts,
          startup,
          workers
        )

      :ignore ->
        loop(state, terminal, runtime, opts, startup, workers)
    end
  end

  defp finish_request_effect(
         state,
         request,
         result,
         terminal,
         runtime,
         opts,
         startup,
         workers
       ) do
    {state, effects} = State.update(state, {:turn_result, request, result})
    workers = if state.request == request, do: workers, else: Workers.stop_subject(workers, request)
    continue_transition(state, effects, terminal, runtime, opts, startup, workers)
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
      {:ok, %{kind: :stream_relay}, workers} ->
        loop(state, terminal, runtime, opts, startup, workers)

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
end
