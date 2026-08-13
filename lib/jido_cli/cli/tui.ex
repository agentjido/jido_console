defmodule Jido.Cli.Tui do
  @moduledoc "Full-screen Jido chat loop."

  alias Jido.Cli.Tui.State
  alias Jido.Cli.Tui.View
  alias Jido.Cli.Coding.Setup
  alias Jido.Cli.Terminal

  @frame_interval_ms 33

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
    state =
      State.new(nil, terminal.size,
        prepare_prompt: true,
        runtime_status: :starting
      )

    with :ok <- Terminal.draw(terminal, View.render(state)) do
      {state, []} = State.update(state, :rendered)
      owner = self()
      {:ok, startup_pid} = Task.start(fn -> runtime_owner(owner, runtime, agent, opts) end)

      try do
        loop(state, terminal, runtime, opts, startup_pid)
      after
        stop_runtime_owner(startup_pid)
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
    close_runtime_session(runtime, startup.session)
    Setup.close(startup.coding)
  end

  defp close_startup_result(_runtime, {:error, _reason}), do: :ok

  defp stop_runtime_owner(startup_pid) do
    if Process.alive?(startup_pid), do: send(startup_pid, {:close, self()})
    :ok
  end

  defp close_runtime_session(runtime, session) do
    if function_exported?(runtime, :close_session, 1), do: runtime.close_session(session), else: :ok
  end

  defp open_terminal(opts) do
    Terminal.open(
      owner: self(),
      adapter: Keyword.get(opts, :terminal_adapter, Jido.Cli.Terminal.OTP),
      adapter_opts: Keyword.get(opts, :terminal_adapter_opts, [])
    )
  end

  defp loop(state, terminal, runtime, opts, startup_pid) do
    receive do
      {:jido_terminal, ref, event} when ref == terminal.ref ->
        continue(state, {:terminal, event}, terminal, runtime, opts, startup_pid)

      {:jidoka_turn_event, event} ->
        continue(state, {:jidoka, event}, terminal, runtime, opts, startup_pid)

      {:jido_turn_result, request, result} ->
        continue(state, {:turn_result, request, result}, terminal, runtime, opts, startup_pid)

      {:jido_runtime_startup, ^startup_pid, {:ok, startup}} ->
        continue(
          state,
          {:runtime_ready, startup.session, startup.coding.instructions},
          terminal,
          runtime,
          startup.opts,
          startup_pid
        )

      {:jido_runtime_startup, ^startup_pid, {:error, reason}} ->
        continue(state, {:runtime_failed, reason}, terminal, runtime, opts, startup_pid)

      :render_frame ->
        case Terminal.draw(terminal, View.render(state)) do
          :ok ->
            {state, []} = State.update(state, :rendered)
            loop(state, terminal, runtime, opts, startup_pid)

          {:error, reason} ->
            {:error, reason}
        end

      _message ->
        loop(state, terminal, runtime, opts, startup_pid)
    end
  end

  defp continue(state, event, terminal, runtime, opts, startup_pid) do
    {state, effects} = State.update(state, event)

    case run_effects(state, effects, runtime, opts) do
      {:continue, state} ->
        state = schedule_render(state)
        loop(state, terminal, runtime, opts, startup_pid)

      :exit ->
        exit_result(state)
    end
  end

  defp exit_result(%State{runtime_status: :failed, startup_error: reason}), do: {:error, reason}
  defp exit_result(_state), do: :ok

  defp run_effects(state, [], _runtime, _opts), do: {:continue, state}
  defp run_effects(_state, [:exit | _effects], _runtime, _opts), do: :exit

  defp run_effects(state, [{:start_turn, prompt} | effects], runtime, opts) do
    run_effects(state, [{:start_turn, prompt, %{}} | effects], runtime, opts)
  end

  defp run_effects(state, [{:prepare_prompt, prompt} | effects], runtime, opts) do
    coding = Keyword.fetch!(opts, :coding_setup_resolved)

    event =
      case Setup.prepare_prompt(coding, prompt) do
        {:ok, prompt, context} -> {:prompt_ready, prompt, context}
        {:error, reason} -> {:prompt_error, reason}
      end

    {state, next_effects} = State.update(state, event)
    run_effects(state, next_effects ++ effects, runtime, opts)
  end

  defp run_effects(state, [{:start_turn, prompt, context} | effects], runtime, opts) do
    turn_opts = Keyword.get(opts, :turn_opts, [])
    turn_opts = Keyword.put(turn_opts, :context, context)

    event =
      case runtime.start_turn(state.session, prompt, self(), turn_opts) do
        {:ok, request} -> {:turn_started, request}
        {:error, reason} -> {:turn_result, {:error, reason}}
      end

    {state, next_effects} = State.update(state, event)
    run_effects(state, next_effects ++ effects, runtime, opts)
  end

  defp run_effects(state, [{:finish_turn, request} | effects], runtime, opts) do
    await_opts = Keyword.get(opts, :await_opts, timeout: 30_000, cancel_on_timeout: false)
    owner = self()

    {:ok, _task} =
      Task.start(fn ->
        result = await_result(runtime, request, await_opts)
        send(owner, {:jido_turn_result, request, result})
      end)

    run_effects(state, effects, runtime, opts)
  end

  defp run_effects(state, [{:cancel_turn, request} | effects], runtime, opts) do
    cancel_opts = Keyword.get(opts, :cancel_opts, [])

    case runtime.cancel(request, cancel_opts) do
      {:ok, cancellation} ->
        {state, next_effects} = State.update(state, {:turn_result, {:cancelled, cancellation}})
        run_effects(state, next_effects ++ effects, runtime, opts)

      {:error, :request_already_finished} ->
        run_effects(state, effects, runtime, opts)

      {:error, reason} ->
        {state, next_effects} = State.update(state, {:turn_result, {:error, reason}})
        run_effects(state, next_effects ++ effects, runtime, opts)
    end
  end

  defp schedule_render(%State{dirty?: true, render_scheduled?: false} = state) do
    Process.send_after(self(), :render_frame, @frame_interval_ms)
    {state, []} = State.update(state, :render_scheduled)
    state
  end

  defp schedule_render(state), do: state

  defp await_result(runtime, request, opts) do
    runtime.await(request, opts)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
