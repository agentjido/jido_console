defmodule Jido.Console.Automation do
  @moduledoc "Runs file-based Jido scenarios and evaluation suites."

  alias Jido.Console.Automation.{Command, Contract, Coordinator, Interrupt, JSONL, Loader, Plan}

  @doc "Parses and executes one automated CLI command."
  @spec execute([String.t()], keyword()) ::
          {:ok, map()}
          | {:error, :usage | :configuration | :execution, term()}
  def execute(args, opts \\ []) do
    with {:ok, command} <- tagged(Command.parse(args), :usage),
         {:ok, suite} <- tagged(suite(command, opts), :configuration),
         {:ok, plan} <- tagged(Plan.build(suite, opts), :configuration),
         output_dir = command.output || suite.output,
         {:ok, sink} <- tagged(JSONL.open(plan.manifest, output_dir, opts), :configuration) do
      run(plan, sink, command, opts)
    end
  end

  defp suite(%Command.Eval{} = command, opts) do
    with {:ok, suite} <- Loader.load_suite(command.suite, opts) do
      jobs = command.jobs || suite.jobs
      {:ok, %{suite | jobs: jobs, command_execution_profile: command.runtime_profile}}
    end
  end

  defp suite(%Command.Run{} = command, opts) do
    with {:ok, scenario} <- command_scenario(command, opts) do
      agent_path = Path.expand(command.agent)
      agent_key = agent_path |> Path.basename() |> Path.rootname() |> path_key()

      models =
        case command.model do
          nil -> [%{key: "declared", source: :agent, ref: nil, generation: nil}]
          model -> [%{key: "override", source: :override, ref: model, generation: nil}]
        end

      suite = %{
        id: "run-#{scenario.id}",
        path: "command:jido-run",
        digest:
          command
          |> Command.digest_projection()
          |> :erlang.term_to_binary([:deterministic])
          |> Loader.digest(),
        agents: [
          %{
            key: agent_key,
            file: agent_path
          }
        ],
        scenarios: [scenario],
        models: models,
        repeats: 1,
        jobs: 1,
        limits: %{},
        execution_profile: nil,
        command_execution_profile: command.runtime_profile,
        output: command.output
      }

      {:ok, suite}
    end
  end

  defp command_scenario(%Command.Run{source: {:scenario, scenario}}, opts),
    do: Loader.load_scenario(scenario, opts)

  defp command_scenario(%Command.Run{source: {:input, input}}, opts),
    do: Loader.scenario_from_input(input, opts)

  defp run(plan, sink, command, opts) do
    started_ms = monotonic_ms(opts)
    jobs = if match?(%Command.Eval{}, command), do: plan.suite.jobs, else: 1
    engine = Keyword.get(opts, :engine, Jido.Console.Automation.Engine.Jidoka)

    case Interrupt.start(self(), opts) do
      {:ok, interrupt} ->
        try do
          coordinator_opts = Keyword.put(opts, :automation_limits, plan.limits)

          case Coordinator.run(plan.cells, sink, engine, jobs, coordinator_opts) do
            {:ok, outcome} ->
              summary = summary(plan, outcome, started_ms, opts)

              case JSONL.finish(sink, summary) do
                :ok -> {:ok, summary}
                {:error, reason} -> {:error, :execution, reason}
              end

            {:error, reason} ->
              execution_failure(sink, reason)
          end
        rescue
          exception -> execution_failure(sink, {:automation_run_exception, exception.__struct__})
        catch
          kind, reason -> execution_failure(sink, {:automation_run_exit, kind, reason})
        after
          Interrupt.stop(interrupt)
        end

      {:error, reason} ->
        execution_failure(sink, reason)
    end
  end

  defp execution_failure(sink, reason) do
    case JSONL.abort(sink, reason) do
      :ok ->
        {:error, :execution, reason}

      {:error, finalization_error} ->
        {:error, :execution, {:automation_failed_with_finalization_error, reason, finalization_error}}
    end
  end

  defp summary(plan, outcome, started_ms, opts) do
    results = outcome.results

    counts =
      Enum.reduce(
        results,
        %{passed: 0, failed: 0, errors: 0, unscored: 0, cancelled: 0},
        &count_result/2
      )

    status =
      cond do
        outcome.stop_cause == :cancelled -> :cancelled
        match?({:limit, _reason}, outcome.stop_cause) -> :failed
        counts.failed == 0 and counts.errors == 0 -> :passed
        true -> :failed
      end

    duration_ms = max(monotonic_ms(opts) - started_ms, 0)

    Contract.summary!(%{
      schema: "jido.run-summary",
      schema_version: 1,
      run_id: plan.run_id,
      suite_id: plan.suite_id,
      status: status,
      planned: length(plan.cells),
      completed: length(results),
      counts: counts,
      duration_ms: duration_ms,
      not_started: Enum.map(outcome.not_started, & &1.cell_id),
      runtime_limits: Jido.Console.Automation.Limits.summary(plan.limits, outcome, duration_ms)
    })
  end

  defp count_result(result, counts) do
    execution = get_in(result, [:execution, :status])
    evaluation = get_in(result, [:evaluation, :status])

    cond do
      execution == :cancelled -> Map.update!(counts, :cancelled, &(&1 + 1))
      execution != :ok -> Map.update!(counts, :errors, &(&1 + 1))
      evaluation == :failed -> Map.update!(counts, :failed, &(&1 + 1))
      evaluation == :unscored -> Map.update!(counts, :unscored, &(&1 + 1))
      true -> Map.update!(counts, :passed, &(&1 + 1))
    end
  end

  defp tagged({:ok, value}, _kind), do: {:ok, value}
  defp tagged({:error, reason}, kind), do: {:error, kind, reason}

  defp path_key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "agent"
      key -> key
    end
  end

  defp monotonic_ms(opts) do
    case Keyword.get(opts, :monotonic_ms) do
      function when is_function(function, 0) -> function.()
      _function -> System.monotonic_time(:millisecond)
    end
  end
end
