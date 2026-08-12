defmodule Jido.Cli.Tui do
  @moduledoc "Full-screen Jido chat loop."

  alias Jido.Cli.Tui.State
  alias Jido.Cli.Tui.View
  alias Jido.Cli.CodingSetup
  alias Jido.Terminal

  @frame_interval_ms 33

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    runtime = Keyword.get(opts, :runtime, Jido.Cli.Runtime.Jidoka)
    agent = Keyword.get(opts, :agent, Jido.Cli.DefaultAgent)
    session_opts = Keyword.get(opts, :session_opts, [])

    with {:ok, coding} <- CodingSetup.prepare(agent, opts),
         session_opts =
           session_opts
           |> Keyword.put(:extension_setup, coding.extension_setup)
           |> Keyword.put(:agent_spec_override, coding.spec),
         {:ok, session} <- runtime.start_session(agent, session_opts),
         {:ok, terminal} <- open_terminal(opts) do
      try do
        state = State.new(session, terminal.size, prepare_prompt: true, project_instructions: coding.instructions)

        with :ok <- Terminal.draw(terminal, View.render(state)) do
          {state, []} = State.update(state, :rendered)
          loop(state, terminal, runtime, Keyword.put(opts, :coding_setup_resolved, coding))
        end
      after
        close_runtime_session(runtime, session)
        Terminal.close(terminal)
      end
    end
  end

  defp close_runtime_session(runtime, session) do
    if function_exported?(runtime, :close_session, 1), do: runtime.close_session(session), else: :ok
  end

  defp open_terminal(opts) do
    Terminal.open(
      owner: self(),
      adapter: Keyword.get(opts, :terminal_adapter, Jido.Terminal.OTP),
      adapter_opts: Keyword.get(opts, :terminal_adapter_opts, [])
    )
  end

  defp loop(state, terminal, runtime, opts) do
    receive do
      {:jido_terminal, ref, event} when ref == terminal.ref ->
        continue(state, {:terminal, event}, terminal, runtime, opts)

      {:jidoka_turn_event, event} ->
        continue(state, {:jidoka, event}, terminal, runtime, opts)

      {:jido_turn_result, request, result} ->
        continue(state, {:turn_result, request, result}, terminal, runtime, opts)

      :render_frame ->
        case Terminal.draw(terminal, View.render(state)) do
          :ok ->
            {state, []} = State.update(state, :rendered)
            loop(state, terminal, runtime, opts)

          {:error, reason} ->
            {:error, reason}
        end

      _message ->
        loop(state, terminal, runtime, opts)
    end
  end

  defp continue(state, event, terminal, runtime, opts) do
    {state, effects} = State.update(state, event)

    case run_effects(state, effects, runtime, opts) do
      {:continue, state} ->
        state = schedule_render(state)
        loop(state, terminal, runtime, opts)

      :exit ->
        :ok
    end
  end

  defp run_effects(state, [], _runtime, _opts), do: {:continue, state}
  defp run_effects(_state, [:exit | _effects], _runtime, _opts), do: :exit

  defp run_effects(state, [{:start_turn, prompt} | effects], runtime, opts) do
    run_effects(state, [{:start_turn, prompt, %{}} | effects], runtime, opts)
  end

  defp run_effects(state, [{:prepare_prompt, prompt} | effects], runtime, opts) do
    coding = Keyword.fetch!(opts, :coding_setup_resolved)

    event =
      case CodingSetup.prepare_prompt(coding, prompt) do
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
