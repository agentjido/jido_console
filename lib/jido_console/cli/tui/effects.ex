defmodule Jido.Console.Tui.Effects do
  @moduledoc false

  alias Jido.Console.Coding.Setup
  alias Jido.Console.Tui.{State, Workers}
  alias Jido.Console.Tui.Workers.Worker

  @type completion ::
          {:event, term()}
          | {:start_turn, pid(), term()}
          | {:review_result, pid(), term()}
          | {:request_result, term(), term()}
          | {:reconfigured, map()}
          | :ignore

  @spec dispatch(State.t(), [State.effect()], module(), keyword(), Workers.t()) ::
          {:continue | :exit, Workers.t()}
  def dispatch(state, effects, runtime, opts, workers) do
    Enum.reduce_while(effects, {:continue, workers}, fn
      :exit, {:continue, workers} ->
        {:halt, {:exit, workers}}

      {:prepare_prompt, prompt}, {:continue, workers} ->
        coding = Keyword.fetch!(opts, :coding_setup_resolved)

        workers =
          Workers.start(workers, {:prepare_prompt, prompt}, nil, fn ->
            prepare_prompt(coding, prompt, opts)
          end)

        {:cont, {:continue, workers}}

      {:apply_selection, selection}, {:continue, workers} ->
        workers =
          Workers.start(workers, {:apply_selection, selection}, nil, fn ->
            apply_selection(selection, opts)
          end)

        {:cont, {:continue, workers}}

      {:start_turn, prompt}, {:continue, workers} ->
        {:cont, {:continue, start_turn(workers, runtime, state.session, opts, prompt, %{})}}

      {:start_turn, prompt, context}, {:continue, workers} ->
        {:cont, {:continue, start_turn(workers, runtime, state.session, opts, prompt, context)}}

      {:await_turn, request}, {:continue, workers} ->
        await_opts = Keyword.get(opts, :await_opts, timeout: 30_000, cancel_on_timeout: false)

        workers =
          Workers.start(workers, :await_turn, request, fn -> runtime.await(request, await_opts) end)

        {:cont, {:continue, workers}}

      {:cancel_turn, request}, {:continue, workers} ->
        cancel_opts = Keyword.get(opts, :cancel_opts, [])

        workers =
          Workers.start(workers, :cancel_turn, request, fn -> runtime.cancel(request, cancel_opts) end)

        {:cont, {:continue, workers}}

      {:respond_review, decision, result, review}, {:continue, workers}
      when decision in [:approve, :deny] ->
        workers =
          Workers.start_review(workers, decision, result, fn relay_pid ->
            respond_to_review(runtime, decision, result, review, opts, relay_pid)
          end)

        {:cont, {:continue, workers}}
    end)
  end

  @spec complete(Worker.t(), {:ok, term()} | {:crash, term()}) :: completion()
  def complete(%Worker{kind: {:apply_selection, _selection}}, outcome) do
    case outcome do
      {:ok, {:ok, startup}} when is_map(startup) -> {:reconfigured, startup}
      {:ok, {:error, reason}} -> {:event, {:prompt_error, reason}}
      {:ok, other} -> {:event, {:prompt_error, {:invalid_selection_result, other}}}
      {:crash, reason} -> {:event, {:prompt_error, reason}}
    end
  end

  def complete(%Worker{kind: {:prepare_prompt, _prompt}}, outcome) do
    event =
      case outcome do
        {:ok, {:ok, prompt, context}} -> {:prompt_ready, prompt, context}
        {:ok, {:error, reason}} -> {:prompt_error, reason}
        {:ok, other} -> {:prompt_error, {:invalid_prompt_result, other}}
        {:crash, reason} -> {:prompt_error, reason}
      end

    {:event, event}
  end

  def complete(%Worker{kind: {:start_turn, relay_pid}}, outcome) do
    event =
      case outcome do
        {:ok, {:ok, request}} -> {:turn_started, request}
        {:ok, {:error, reason}} -> {:turn_result, {:error, reason}}
        {:ok, other} -> {:turn_result, {:error, {:invalid_start_turn_result, other}}}
        {:crash, reason} -> {:turn_result, {:error, reason}}
      end

    {:start_turn, relay_pid, event}
  end

  def complete(%Worker{kind: :await_turn, subject: request}, outcome) do
    result = unwrap(outcome)
    {:request_result, request, result}
  end

  def complete(%Worker{kind: :cancel_turn, subject: request}, outcome) do
    case outcome do
      {:ok, {:ok, cancellation}} -> {:request_result, request, {:cancelled, cancellation}}
      {:ok, {:error, :request_already_finished}} -> :ignore
      {:ok, {:error, reason}} -> {:request_result, request, {:error, reason}}
      {:ok, other} -> {:request_result, request, {:error, {:invalid_cancel_result, other}}}
      {:crash, reason} -> {:request_result, request, {:error, reason}}
    end
  end

  def complete(%Worker{kind: {:respond_review, _decision, relay_pid}}, outcome) do
    {:review_result, relay_pid, unwrap(outcome)}
  end

  defp apply_selection(selection, opts) do
    case Keyword.get(opts, :runtime_owner) do
      pid when is_pid(pid) ->
        send(pid, {:reconfigure, self(), selection})

        receive do
          {:jido_runtime_reconfigure, ^pid, result} -> result
        after
          60_000 -> {:error, :selection_apply_timeout}
        end

      _missing ->
        {:error, :runtime_owner_missing}
    end
  end

  defp start_turn(workers, runtime, session, opts, prompt, context) do
    turn_opts = opts |> Keyword.get(:turn_opts, []) |> Keyword.put(:context, context)

    Workers.start_turn(workers, fn relay_pid ->
      runtime.start_turn(session, prompt, relay_pid, turn_opts)
    end)
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:crash, reason}), do: {:error, reason}

  defp prepare_prompt(coding, prompt, opts) do
    case Keyword.get(opts, :prompt_preparer) do
      nil -> Setup.prepare_prompt(coding, prompt)
      prompt_preparer when is_function(prompt_preparer, 2) -> prompt_preparer.(coding, prompt)
      _invalid -> {:error, :invalid_prompt_preparer}
    end
  end

  defp respond_to_review(runtime, decision, result, review, opts, relay_pid) do
    callback = if decision == :approve, do: :approve, else: :deny

    review_opts =
      opts
      |> Keyword.get(:review_opts, [])
      |> Keyword.put(:stream, true)
      |> Keyword.put(:stream_to, relay_pid)

    if function_exported?(runtime, callback, 3) do
      apply(runtime, callback, [result, review, review_opts])
    else
      {:error, {:runtime_review_response_unsupported, decision}}
    end
  end
end
