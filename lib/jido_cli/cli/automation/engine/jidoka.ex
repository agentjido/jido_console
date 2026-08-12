defmodule Jido.Cli.Automation.Engine.Jidoka do
  @moduledoc "Runs one scenario in one caller-managed Jidoka session."

  @behaviour Jido.Cli.Automation.Engine

  alias Jido.Cli.Automation.Result
  alias Jidoka.Effect.OperationResult
  alias Jidoka.Eval
  alias Jidoka.Eval.Case, as: EvalCase
  alias Jidoka.Session.Sequence

  @impl true
  def run(cell, opts) do
    started_at = utc_now(opts)
    started_ms = monotonic_ms(opts)

    do_run(cell, opts, started_at, started_ms)
  end

  defp do_run(cell, opts, started_at, started_ms) do
    case Jidoka.Session.start(cell.spec, session_id: session_id(cell)) do
      {:ok, session} ->
        execute_turns(cell, session, opts, started_at, started_ms)

      {:error, reason} ->
        failed_result(cell, :error, [], reason, started_at, elapsed_ms(started_ms, opts))
    end
  rescue
    exception ->
      failed_result(
        cell,
        :error,
        [],
        exception,
        started_at,
        elapsed_ms(started_ms, opts)
      )
  catch
    kind, reason ->
      failed_result(
        cell,
        :error,
        [],
        {kind, reason},
        started_at,
        elapsed_ms(started_ms, opts)
      )
  end

  defp execute_turns(cell, session, opts, started_at, started_ms) do
    request_inputs = Enum.map(cell.scenario.turns, &request_input(&1, cell))
    runtime_opts = Keyword.merge(cell.runtime_opts, Keyword.take(opts, [:id_generator]))

    case Jidoka.Session.run_sequence(session, request_inputs, runtime_opts) do
      {:ok, %Sequence.Result{} = sequence} ->
        map_sequence_result(cell, sequence, opts, started_at, started_ms)

      {:error, reason} ->
        failed_result(cell, :error, [], reason, started_at, elapsed_ms(started_ms, opts))
    end
  end

  defp map_sequence_result(cell, sequence, opts, started_at, started_ms) do
    turns =
      Enum.map(sequence.steps, fn step ->
        turn = Enum.at(cell.scenario.turns, step.index - 1)
        completed_turn(cell, turn, step, started_ms, opts)
      end)

    duration_ms = elapsed_ms(started_ms, opts)

    case sequence.status do
      :completed ->
        completed_result(cell, turns, started_at, duration_ms)

      status when status in [:error, :hibernated, :cancelled] ->
        terminal = sequence.terminal
        turn = Enum.at(cell.scenario.turns, terminal.index - 1)

        interrupted =
          interrupted_turn(
            turn,
            status,
            terminal_reason(terminal),
            started_ms,
            opts,
            terminal.request_id
          )

        failed_result(
          cell,
          status,
          turns ++ [interrupted],
          terminal_reason(terminal),
          started_at,
          duration_ms
        )
    end
  end

  defp request_input(turn, cell) do
    %{
      input: turn.input,
      context: turn.context,
      metadata: %{
        "automation" => %{
          "run_id" => cell.run_id,
          "cell_id" => cell.cell_id,
          "scenario_id" => cell.dimensions.scenario_id,
          "turn_id" => turn.id
        }
      }
    }
  end

  defp completed_turn(cell, turn, step, started_ms, opts) do
    assertions = evaluate(cell, turn, step.request, step.result, step.operation_results)

    %{
      turn_id: turn.id,
      request_id: step.request.request_id,
      input: turn.input,
      status: :ok,
      duration_ms: elapsed_ms(started_ms, opts),
      response: %{
        content: step.result.content,
        value: Jidoka.project(step.result.value)
      },
      evaluation: turn_evaluation(assertions),
      observations: %{
        operation_calls: Enum.map(step.operation_results, &operation_name/1),
        event_count: length(step.result.events),
        journal_intents: map_size(step.result.journal.intents),
        journal_results: map_size(step.result.journal.results)
      },
      usage: Jidoka.project(step.result.usage)
    }
  end

  defp evaluate(cell, turn, request, result, current_operations) do
    scoped_agent_state = %{result.agent_state | operation_results: current_operations}
    scoped_result = %{result | agent_state: scoped_agent_state}

    with {:ok, eval_case} <-
           EvalCase.new(%{
             id: "#{cell.cell_id}:#{turn.id}",
             agent: cell.spec,
             request: request,
             assertions: turn.assertions
           }) do
      Eval.evaluate(eval_case, scoped_result)
    else
      {:error, reason} ->
        [
          %{
            name: :eval_case,
            status: :failed,
            expected: turn.assertions,
            actual: Result.error(reason)
          }
        ]
    end
  end

  defp turn_evaluation(assertions) do
    status =
      cond do
        assertions == [] -> :unscored
        Enum.any?(assertions, &(Map.get(&1, :status) == :failed)) -> :failed
        true -> :passed
      end

    %{status: status, assertions: Jidoka.project(assertions)}
  end

  defp interrupted_turn(turn, status, reason, started_ms, opts, request_id) do
    turn_result = %{
      turn_id: turn.id,
      input: turn.input,
      status: status,
      duration_ms: elapsed_ms(started_ms, opts),
      response: nil,
      evaluation: %{status: :not_run, assertions: []},
      observations: %{},
      usage: %{},
      error: Result.error(reason)
    }

    if is_binary(request_id), do: Map.put(turn_result, :request_id, request_id), else: turn_result
  end

  defp terminal_reason(%Sequence.Terminal{snapshot: snapshot}) when not is_nil(snapshot),
    do: snapshot

  defp terminal_reason(%Sequence.Terminal{cancellation: cancellation})
       when not is_nil(cancellation),
       do: cancellation

  defp terminal_reason(%Sequence.Terminal{reason: reason}), do: reason

  defp completed_result(cell, turns, started_at, duration_ms) do
    evaluation = Result.evaluation(turns, :ok)

    Result.new(cell,
      execution: %{
        status: :ok,
        started_at: DateTime.to_iso8601(started_at),
        duration_ms: duration_ms,
        turn_count: length(turns)
      },
      evaluation: evaluation,
      turns: turns,
      usage: Result.usage(turns),
      error: nil
    )
  end

  defp failed_result(cell, status, turns, reason, started_at, duration_ms) do
    Result.new(cell,
      execution: %{
        status: status,
        started_at: DateTime.to_iso8601(started_at),
        duration_ms: duration_ms,
        turn_count: length(turns)
      },
      evaluation: Result.evaluation(turns, status),
      turns: turns,
      usage: Result.usage(turns),
      error: Result.error(reason)
    )
  end

  defp operation_name(%OperationResult{operation: operation}), do: operation
  defp operation_name(%{operation: operation}), do: operation
  defp operation_name(_operation), do: nil

  defp session_id(cell), do: "sess-" <> String.slice(cell.cell_id, 0, 32)

  defp utc_now(opts) do
    case Keyword.get(opts, :utc_now) do
      function when is_function(function, 0) -> function.()
      _function -> DateTime.utc_now()
    end
  end

  defp monotonic_ms(opts) do
    case Keyword.get(opts, :monotonic_ms) do
      function when is_function(function, 0) -> function.()
      _function -> System.monotonic_time(:millisecond)
    end
  end

  defp elapsed_ms(started_ms, opts), do: max(monotonic_ms(opts) - started_ms, 0)
end
