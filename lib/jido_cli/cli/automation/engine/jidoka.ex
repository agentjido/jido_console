defmodule Jido.Cli.Automation.Engine.Jidoka do
  @moduledoc "Runs one scenario in one caller-managed Jidoka session."

  @behaviour Jido.Cli.Automation.Engine

  alias Jido.Cli.Automation.Result
  alias Jidoka.Effect.OperationResult
  alias Jidoka.Eval
  alias Jidoka.Eval.Case, as: EvalCase
  alias Jidoka.Turn

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
    initial = %{session: session, agent_state: nil, operation_count: 0, turns: []}

    result =
      Enum.reduce_while(cell.scenario.turns, {:ok, initial}, fn turn, {:ok, state} ->
        case execute_turn(cell, turn, state, opts) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:halt, status, next_state, reason} -> {:halt, {:halt, status, next_state, reason}}
        end
      end)

    duration_ms = elapsed_ms(started_ms, opts)

    case result do
      {:ok, state} ->
        completed_result(cell, state.turns, started_at, duration_ms)

      {:halt, status, state, reason} ->
        failed_result(cell, status, state.turns, reason, started_at, duration_ms)
    end
  end

  defp execute_turn(cell, turn, state, opts) do
    started_ms = monotonic_ms(opts)

    with {:ok, request} <- request(turn, state.agent_state, cell, opts) do
      case Jidoka.Session.run(state.session, request, cell.runtime_opts) do
        {:ok, session, %Turn.Result{} = result} ->
          current_operations =
            Enum.drop(result.agent_state.operation_results, state.operation_count)

          assertions = evaluate(cell, turn, request, result, current_operations)

          turn_result = %{
            turn_id: turn.id,
            request_id: request.request_id,
            input: turn.input,
            status: :ok,
            duration_ms: elapsed_ms(started_ms, opts),
            response: %{
              content: result.content,
              value: Jidoka.project(result.value)
            },
            evaluation: turn_evaluation(assertions),
            observations: %{
              operation_calls: Enum.map(current_operations, &operation_name/1),
              event_count: length(result.events),
              journal_intents: map_size(result.journal.intents),
              journal_results: map_size(result.journal.results)
            },
            usage: Jidoka.project(result.usage)
          }

          {:ok,
           %{
             state
             | session: session,
               agent_state: result.agent_state,
               operation_count: length(result.agent_state.operation_results),
               turns: state.turns ++ [turn_result]
           }}

        {:hibernate, session, snapshot} ->
          turn_result = interrupted_turn(turn, :hibernated, snapshot, started_ms, opts)

          {:halt, :hibernated, %{state | session: session, turns: state.turns ++ [turn_result]}, snapshot}

        {:error, reason} ->
          turn_result = interrupted_turn(turn, :error, reason, started_ms, opts)
          {:halt, :error, %{state | turns: state.turns ++ [turn_result]}, reason}
      end
    else
      {:error, reason} ->
        turn_result = interrupted_turn(turn, :error, reason, started_ms, opts)
        {:halt, :error, %{state | turns: state.turns ++ [turn_result]}, reason}
    end
  end

  defp request(turn, agent_state, cell, opts) do
    attrs = %{
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

    attrs = if agent_state, do: Map.put(attrs, :agent_state, agent_state), else: attrs
    Turn.Request.new(attrs, Keyword.take(opts, [:id_generator]))
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

  defp interrupted_turn(turn, status, reason, started_ms, opts) do
    %{
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
  end

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
