defmodule Jido.Cli.Automation.Engine.Jidoka do
  @moduledoc "Runs one scenario in one caller-managed Jidoka session."

  @behaviour Jido.Cli.Automation.Engine

  alias Jido.Cli.Automation.Result
  alias Jidoka.Effect.OperationResult
  alias Jidoka.Eval
  alias Jidoka.Eval.Case, as: EvalCase
  alias Jidoka.Session.Sequence

  defmodule Request do
    @moduledoc false

    @enforce_keys [:cell, :sequence, :started_at, :started_ms]
    defstruct [:cell, :sequence, :started_at, :started_ms]

    @type t :: %__MODULE__{
            cell: map(),
            sequence: Jidoka.Session.Sequence.Request.t(),
            started_at: DateTime.t(),
            started_ms: integer()
          }
  end

  @impl true
  def run(cell, opts) do
    case start(cell, opts) do
      {:ok, %Request{} = request} -> await(request, opts)
      {:error, reason} -> failed_result(cell, :error, [], reason, utc_now(opts), 0)
    end
  end

  @impl true
  def start(cell, opts) do
    started_at = utc_now(opts)
    started_ms = monotonic_ms(opts)

    with {:ok, session} <- Jidoka.Session.start(cell.spec, session_id: session_id(cell)),
         request_inputs = Enum.map(cell.scenario.turns, &request_input(&1, cell)),
         runtime_opts = sequence_runtime_opts(cell, opts),
         {:ok, sequence} <-
           Jidoka.Session.run_sequence_async(session, request_inputs, runtime_opts) do
      {:ok,
       %Request{
         cell: cell,
         sequence: sequence,
         started_at: started_at,
         started_ms: started_ms
       }}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @impl true
  def await(%Request{} = request, opts) do
    await_opts = [timeout: Keyword.get(opts, :automation_await_timeout, :infinity)]

    case Jidoka.await(request.sequence, await_opts) do
      {:ok, %Sequence.Result{} = sequence} ->
        map_sequence_result(request.cell, sequence, opts, request.started_at, request.started_ms)

      {:cancelled, _cancellation, %Sequence.Result{} = sequence} ->
        map_sequence_result(request.cell, sequence, opts, request.started_at, request.started_ms)

      {:error, reason} ->
        failed_result(
          request.cell,
          :error,
          [],
          reason,
          request.started_at,
          elapsed_ms(request.started_ms, opts)
        )
    end
  rescue
    exception ->
      failed_result(
        request.cell,
        :error,
        [],
        exception,
        request.started_at,
        elapsed_ms(request.started_ms, opts)
      )
  catch
    kind, reason ->
      failed_result(
        request.cell,
        :error,
        [],
        {kind, reason},
        request.started_at,
        elapsed_ms(request.started_ms, opts)
      )
  end

  @impl true
  def cancel(%Request{} = request, opts) do
    Jidoka.cancel(request.sequence, opts)
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

  defp sequence_runtime_opts(cell, opts) do
    cell.runtime_opts
    |> Keyword.merge(
      Keyword.take(opts, [
        :id_generator,
        :execution_environment_policy,
        :execution_environment_adapter_opts
      ])
    )
    |> maybe_put_execution_environment(Map.get(cell, :execution_environment))
    |> Keyword.put(:sequence_request_id, "cell-" <> cell.cell_id)
    |> Keyword.put(:sequence_metadata, %{
      "run_id" => cell.run_id,
      "cell_id" => cell.cell_id
    })
  end

  defp maybe_put_execution_environment(opts, nil), do: opts

  defp maybe_put_execution_environment(opts, environment),
    do: Keyword.put(opts, :execution_environment, environment)

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
