defmodule Jido.Console.Automation.Engine.Jidoka do
  @moduledoc "Runs one scenario in one caller-managed Jidoka session."

  @behaviour Jido.Console.Automation.Engine

  alias Jido.Console.Automation.{Limits, Replay, Result}
  alias Jido.Console.Extensions
  alias Jido.Console.Session.{Client, Server}
  alias Jido.Console.Session.Client.Automation, as: SessionAutomation
  alias Jidoka.Effect.OperationResult
  alias Jidoka.Eval
  alias Jidoka.Eval.Case, as: EvalCase
  alias Jidoka.Session.Sequence

  defmodule Request do
    @moduledoc false

    @enforce_keys [:cell, :client, :request]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            cell: map(),
            client: Jido.Console.Session.Client.t(),
            request: Jido.Console.Session.Request.t()
          }
  end

  defmodule OwnedRequest do
    @moduledoc false

    @enforce_keys [:cell, :sequence, :started_at, :started_ms]
    defstruct [:cell, :sequence, :started_at, :started_ms, :extension_host, :replay_player]

    @type t :: %__MODULE__{
            cell: map(),
            sequence: Jidoka.Session.Sequence.Request.t(),
            started_at: DateTime.t(),
            started_ms: integer(),
            extension_host: Jidoka.Extension.Host.t() | nil,
            replay_player: Jidoka.Replay.Recorder.controller() | nil
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
    session_id = session_id(cell)

    with {:ok, client} <-
           SessionAutomation.attach_cell(
             session_id,
             Keyword.take(opts, [:registry, :supervisor, :tasks])
           ) do
      spec = [
        start: fn owner -> start_owned(cell, opts, started_at, started_ms, owner, session_id) end,
        await: fn owned -> await_owned(owned, opts) end,
        cancel: fn owned, cancel_opts -> Jidoka.cancel(owned.sequence, cancel_opts) end,
        request_id: "cell-" <> cell.cell_id,
        run_id: cell.run_id
      ]

      case Client.start_operation(client, spec) do
        {:ok, %Jido.Console.Session.Request{} = request} ->
          {:ok, %Request{cell: cell, client: client, request: request}}

        {:error, reason} ->
          cleanup_client(client)
          {:error, reason}
      end
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_owned(cell, opts, started_at, started_ms, owner, session_id) do
    with {:ok, session} <- Jidoka.Session.start(cell.spec, session_id: session_id),
         {:ok, extension_runtime} <-
           Extensions.open(
             session,
             cell.spec.extensions,
             Map.get(cell, :extensions, Jido.Console.Extensions.Setup.not_requested()),
             :automation,
             operations: Keyword.get(cell.runtime_opts, :operations)
           ) do
      start_sequence(cell, extension_runtime, opts, started_at, started_ms, owner)
    end
  end

  defp start_sequence(cell, extension_runtime, opts, started_at, started_ms, owner) do
    replay = Map.get(cell, :capability_replay, %{mode: :live})

    case Replay.open(replay) do
      {:ok, replay_player} ->
        start_sequence_request(
          cell,
          extension_runtime,
          replay_player,
          opts,
          started_at,
          started_ms,
          owner
        )

      {:error, reason} ->
        Extensions.close(extension_runtime.host)
        {:error, reason}
    end
  end

  defp start_sequence_request(
         cell,
         extension_runtime,
         replay_player,
         opts,
         started_at,
         started_ms,
         owner
       ) do
    request_inputs = Enum.map(cell.scenario.turns, &request_input(&1, cell))

    runtime_opts =
      cell
      |> sequence_runtime_opts(opts)
      |> Keyword.merge(extension_runtime.runtime_opts)
      |> Replay.put_runtime(replay_player)
      |> Keyword.put(:stream, true)
      |> Keyword.put(:stream_to, owner)

    case Jidoka.Session.run_sequence_async(extension_runtime.session, request_inputs, runtime_opts) do
      {:ok, sequence} ->
        Jidoka.Extension.RuntimeEvents.emit(
          "automation.cell.start",
          %{session_ref: extension_runtime.session.session_id, data: %{cell_id: cell.cell_id}},
          runtime_opts
        )

        {:ok,
         %OwnedRequest{
           cell: cell,
           sequence: sequence,
           started_at: started_at,
           started_ms: started_ms,
           extension_host: extension_runtime.host,
           replay_player: replay_player
         }}

      {:error, reason} ->
        Replay.stop(replay_player)
        Extensions.close(extension_runtime.host)
        {:error, reason}
    end
  rescue
    exception ->
      Replay.stop(replay_player)
      Extensions.close(extension_runtime.host)
      {:error, exception}
  catch
    kind, reason ->
      Replay.stop(replay_player)
      Extensions.close(extension_runtime.host)
      {:error, {kind, reason}}
  end

  @impl true
  def await(%Request{} = request, opts) do
    timeout = Keyword.get(opts, :automation_await_timeout, :infinity)
    result = Client.await(request.client, request.request, timeout)
    cleanup_client(request.client)
    result
  end

  defp await_owned(%OwnedRequest{} = request, opts) do
    await_opts = [timeout: await_timeout(request.cell, opts)]

    result =
      case Jidoka.await(request.sequence, await_opts) do
        {:ok, %Sequence.Result{} = sequence} ->
          map_sequence_with_extensions(request, sequence, opts)

        {:cancelled, _cancellation, %Sequence.Result{} = sequence} ->
          map_sequence_with_extensions(request, sequence, opts)

        {:error, reason} ->
          failed_result(
            request.cell,
            :error,
            [],
            reason,
            request.started_at,
            elapsed_ms(request.started_ms, opts),
            nil
          )
      end

    close_result = Extensions.close(request.extension_host)

    result
    |> apply_extension_close(close_result)
    |> Replay.finalize(Map.get(request.cell, :capability_replay, %{mode: :live}), request.replay_player)
  rescue
    exception ->
      Replay.stop(request.replay_player)
      Extensions.close(request.extension_host)

      failed_result(
        request.cell,
        :error,
        [],
        exception,
        request.started_at,
        elapsed_ms(request.started_ms, opts),
        nil
      )
  catch
    kind, reason ->
      Replay.stop(request.replay_player)
      Extensions.close(request.extension_host)

      failed_result(
        request.cell,
        :error,
        [],
        {kind, reason},
        request.started_at,
        elapsed_ms(request.started_ms, opts),
        nil
      )
  end

  defp map_sequence_with_extensions(request, sequence, opts) do
    {sequence, extension_results} = checkpoint_extensions(sequence, request.extension_host)

    Jidoka.Extension.RuntimeEvents.emit(
      "automation.cell.end",
      %{session_ref: sequence.session.session_id, data: %{cell_id: request.cell.cell_id, status: sequence.status}},
      extension_event_opts(request.extension_host)
    )

    map_sequence_result(
      request.cell,
      sequence,
      opts,
      request.started_at,
      request.started_ms,
      extension_results
    )
  end

  defp checkpoint_extensions(sequence, nil), do: {sequence, %{}}

  defp checkpoint_extensions(sequence, host) do
    session =
      case Jidoka.Extension.Host.checkpoint(host, sequence.session) do
        {:ok, checkpointed} -> checkpointed
        {:error, _reason} -> sequence.session
      end

    {:ok, results} = Extensions.results(host)

    {%{sequence | session: session}, results}
  end

  defp extension_event_opts(nil), do: []
  defp extension_event_opts(host), do: [extension_dispatcher: host.dispatcher]

  defp apply_extension_close(result, {:ok, evidence}) do
    if Enum.any?(evidence, &(Map.get(&1, "status") == "close_failed")) do
      result
      |> put_in([:execution, :status], :error)
      |> Map.put(:evaluation, Result.evaluation([], :error))
      |> Map.put(:error, Result.error({:extension_close_failed, evidence}))
    else
      result
    end
  end

  @impl true
  def cancel(%Request{} = request, opts) do
    Client.cancel_and_wait(request.client, request.request, opts)
  end

  defp map_sequence_result(cell, sequence, opts, started_at, started_ms, extension_results) do
    turns =
      Enum.map(sequence.steps, fn step ->
        turn = Enum.at(cell.scenario.turns, step.index - 1)
        completed_turn(cell, turn, step, started_ms, opts)
      end)

    duration_ms = elapsed_ms(started_ms, opts)

    case sequence.status do
      :completed ->
        completed_result(
          cell,
          turns,
          sequence.session.environment,
          started_at,
          duration_ms,
          extension_results,
          sequence.limits
        )

      status when status in [:error, :hibernated, :cancelled] ->
        terminal = sequence.terminal
        turn = Enum.at(cell.scenario.turns, terminal.index - 1)

        terminal_turns =
          if Enum.any?(sequence.steps, &(&1.index == terminal.index)) do
            turns
          else
            turns ++
              [
                interrupted_turn(
                  turn,
                  status,
                  terminal_reason(terminal),
                  started_ms,
                  opts,
                  terminal.request_id
                )
              ]
          end

        failed_result(
          cell,
          status,
          terminal_turns,
          terminal_reason(terminal),
          started_at,
          duration_ms,
          sequence.session.environment,
          extension_results,
          sequence.limits
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

    case EvalCase.new(%{
           id: "#{cell.cell_id}:#{turn.id}",
           agent: cell.spec,
           request: request,
           assertions: turn.assertions
         }) do
      {:ok, eval_case} ->
        Eval.evaluate(eval_case, scoped_result)

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

  defp completed_result(cell, turns, environment, started_at, duration_ms, extension_results, limits) do
    evaluation = Result.evaluation(turns, :ok)

    Result.new(cell,
      execution: %{
        status: :ok,
        started_at: DateTime.to_iso8601(started_at),
        duration_ms: duration_ms,
        turn_count: length(turns)
      },
      environment: environment,
      evaluation: evaluation,
      turns: turns,
      usage: Result.usage(turns),
      error: nil,
      extensions: extension_results,
      runtime_limit_evidence: limits
    )
  end

  defp failed_result(
         cell,
         status,
         turns,
         reason,
         started_at,
         duration_ms,
         environment \\ nil,
         extension_results \\ %{},
         limits \\ nil
       ) do
    Result.new(cell,
      execution: %{
        status: status,
        started_at: DateTime.to_iso8601(started_at),
        duration_ms: duration_ms,
        turn_count: length(turns)
      },
      environment: environment,
      environment_error: reason,
      evaluation: Result.evaluation(turns, status),
      turns: turns,
      usage: Result.usage(turns),
      error: Result.error(reason),
      extensions: extension_results,
      runtime_limit_evidence: limits,
      runtime_limit_error: reason
    )
  end

  defp operation_name(%OperationResult{operation: operation}), do: operation
  defp operation_name(%{operation: operation}), do: operation
  defp operation_name(_operation), do: nil

  defp session_id(cell) do
    suffix = System.unique_integer([:positive, :monotonic])
    "sess-#{String.slice(cell.cell_id, 0, 24)}-#{suffix}"
  end

  defp sequence_runtime_opts(cell, opts) do
    cell.runtime_opts
    |> Keyword.merge(
      Keyword.take(opts, [
        :id_generator,
        :execution_environment_policy,
        :execution_environment_adapter_opts
      ])
    )
    |> maybe_put_execution_environment(cell)
    |> maybe_put_runtime_limits(cell)
    |> Keyword.put(:sequence_request_id, "cell-" <> cell.cell_id)
    |> Keyword.put(:sequence_metadata, %{
      "run_id" => cell.run_id,
      "cell_id" => cell.cell_id
    })
  end

  defp maybe_put_execution_environment(opts, %{capability_replay: %{mode: :replay}}), do: opts
  defp maybe_put_execution_environment(opts, %{execution_environment: nil}), do: opts

  defp maybe_put_execution_environment(opts, %{execution_environment: environment}),
    do: Keyword.put(opts, :execution_environment, environment)

  defp maybe_put_execution_environment(opts, _cell), do: opts

  defp maybe_put_runtime_limits(opts, %{runtime_limits: limits}),
    do: Keyword.put(opts, :runtime_limits, Limits.jidoka(limits))

  defp maybe_put_runtime_limits(opts, _cell), do: opts

  defp await_timeout(%{runtime_limits: limits}, opts) do
    min(Keyword.get(opts, :automation_await_timeout, Limits.cell_timeout_ms(limits)), Limits.cell_timeout_ms(limits))
  end

  defp await_timeout(_cell, opts), do: Keyword.get(opts, :automation_await_timeout, :infinity)

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

  defp cleanup_client(client) do
    _ = Client.detach(client)
    Server.stop(client.server)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
