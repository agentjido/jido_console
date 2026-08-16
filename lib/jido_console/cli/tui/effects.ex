defmodule Jido.Console.Tui.Effects do
  @moduledoc false

  alias Jido.Console.Coding.Setup
  alias Jido.Console.Session.Client
  alias Jido.Console.Tui.{State, Workers}
  alias Jido.Console.Tui.Workers.Worker

  @type completion ::
          {:event, term()}
          | {:reconfigured, map()}
          | :ignore

  @spec dispatch(State.t(), [State.effect()], module(), keyword(), Workers.t()) ::
          {:continue | :exit, Workers.t()}
  def dispatch(state, effects, _runtime, opts, workers) do
    Enum.reduce_while(effects, {:continue, workers}, fn
      :exit, {:continue, workers} ->
        {:halt, {:exit, workers}}

      {:prepare_prompt, prompt}, {:continue, workers} ->
        coding = Keyword.fetch!(opts, :coding_setup_resolved)

        workers =
          Workers.start(workers, {:prepare_prompt, prompt}, fn ->
            prepare_prompt(coding, prompt, opts)
          end)

        {:cont, {:continue, workers}}

      {:apply_selection, selection}, {:continue, workers} ->
        workers =
          Workers.start(workers, {:apply_selection, selection}, fn ->
            apply_selection(selection, opts)
          end)

        {:cont, {:continue, workers}}

      {:start_turn, prompt}, {:continue, workers} ->
        {:cont, {:continue, start_turn(workers, state.session_client, opts, prompt, %{})}}

      {:start_turn, prompt, context}, {:continue, workers} ->
        {:cont, {:continue, start_turn(workers, state.session_client, opts, prompt, context)}}

      {:cancel_turn, request}, {:continue, workers} ->
        cancel_opts = Keyword.get(opts, :cancel_opts, [])

        workers =
          Workers.start(workers, :session_cancel, fn ->
            Client.cancel(state.session_client, request, cancel_opts)
          end)

        {:cont, {:continue, workers}}

      {:respond_review, decision, request, _result, review}, {:continue, workers}
      when decision in [:approve, :deny] ->
        workers =
          Workers.start(workers, {:session_review, decision}, fn ->
            review_opts = Keyword.get(opts, :review_opts, [])
            Client.respond_review(state.session_client, decision, request, review, review_opts)
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

  def complete(%Worker{kind: :session_start_turn}, outcome) do
    case outcome do
      {:ok, {:ok, _request}} -> :ignore
      {:ok, {:error, reason}} -> {:event, {:turn_result, {:error, reason}}}
      {:ok, other} -> {:event, {:turn_result, {:error, {:invalid_start_turn_result, other}}}}
      {:crash, reason} -> {:event, {:turn_result, {:error, reason}}}
    end
  end

  def complete(%Worker{kind: :session_cancel}, outcome) do
    case outcome do
      {:ok, {:ok, :requested}} -> :ignore
      {:ok, {:error, :request_already_finished}} -> :ignore
      {:ok, {:error, reason}} -> {:event, {:turn_result, {:error, reason}}}
      {:ok, other} -> {:event, {:turn_result, {:error, {:invalid_cancel_result, other}}}}
      {:crash, reason} -> {:event, {:turn_result, {:error, reason}}}
    end
  end

  def complete(%Worker{kind: {:session_review, _decision}}, outcome) do
    case outcome do
      {:ok, {:ok, :requested}} -> :ignore
      {:ok, {:error, reason}} -> {:event, {:turn_result, {:error, reason}}}
      {:ok, other} -> {:event, {:turn_result, {:error, {:invalid_review_result, other}}}}
      {:crash, reason} -> {:event, {:turn_result, {:error, reason}}}
    end
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

  defp start_turn(workers, session_client, opts, prompt, context) do
    turn_opts = opts |> Keyword.get(:turn_opts, []) |> Keyword.put(:context, context)
    await_opts = Keyword.get(opts, :await_opts, timeout: 30_000, cancel_on_timeout: false)

    Workers.start(workers, :session_start_turn, fn ->
      Client.start_turn(session_client, prompt, turn_opts: turn_opts, await_opts: await_opts)
    end)
  end

  defp prepare_prompt(coding, prompt, opts) do
    case Keyword.get(opts, :prompt_preparer) do
      nil -> Setup.prepare_prompt(coding, prompt)
      prompt_preparer when is_function(prompt_preparer, 2) -> prompt_preparer.(coding, prompt)
      _invalid -> {:error, :invalid_prompt_preparer}
    end
  end
end
