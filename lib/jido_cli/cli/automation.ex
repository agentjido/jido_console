defmodule Jido.Cli.Automation do
  @moduledoc "Runs file-based Jido scenarios and evaluation suites."

  alias Jido.Cli.Automation.{Command, JSONL, Loader, Plan, Result}

  @doc "Parses and executes one automated CLI command."
  @spec execute([String.t()], keyword()) ::
          {:ok, map()}
          | {:error, :usage | :configuration | :execution, term()}
  def execute(args, opts \\ []) do
    with {:ok, command} <- tagged(Command.parse(args), :usage),
         {:ok, suite} <- tagged(suite(command, opts), :configuration),
         {:ok, plan} <- tagged(Plan.build(suite, opts), :configuration),
         output_dir = Map.get(command, :output) || suite.output,
         {:ok, sink} <- tagged(JSONL.open(plan.manifest, output_dir, opts), :configuration) do
      run(plan, sink, command, opts)
    end
  end

  defp suite(%{name: :eval} = command, opts) do
    with {:ok, suite} <- Loader.load_suite(command.suite, opts) do
      jobs = Map.get(command, :jobs, suite.jobs)
      {:ok, %{suite | jobs: jobs}}
    end
  end

  defp suite(%{name: :run} = command, opts) do
    with {:ok, scenario} <- command_scenario(command, opts) do
      agent_path = Path.expand(command.agent)
      agent_key = agent_path |> Path.basename() |> Path.rootname() |> path_key()

      models =
        case Map.get(command, :model) do
          nil -> [%{key: "declared", source: :agent, ref: nil, generation: nil}]
          model -> [%{key: "override", source: :override, ref: model, generation: nil}]
        end

      suite = %{
        id: "run-#{scenario.id}",
        path: "command:jido-run",
        digest: Loader.digest(:erlang.term_to_binary(command, [:deterministic])),
        agents: [
          %{
            key: agent_key,
            file: agent_path,
            runtime_profile: Map.get(command, :runtime_profile)
          }
        ],
        scenarios: [scenario],
        models: models,
        repeats: 1,
        jobs: 1,
        output: Map.get(command, :output)
      }

      {:ok, suite}
    end
  end

  defp command_scenario(%{scenario: path}, opts), do: Loader.load_scenario(path, opts)
  defp command_scenario(%{input: path}, opts), do: Loader.scenario_from_input(path, opts)

  defp run(plan, sink, command, opts) do
    started_ms = System.monotonic_time(:millisecond)
    jobs = if command.name == :eval, do: plan.suite.jobs, else: 1
    engine = Keyword.get(opts, :engine, Jido.Cli.Automation.Engine.Jidoka)

    stream =
      Task.async_stream(
        plan.cells,
        fn cell -> safe_engine_run(engine, cell, opts) end,
        ordered: false,
        max_concurrency: jobs,
        timeout: :infinity
      )

    with {:ok, results} <- emit_results(stream, sink, []),
         summary <- summary(plan, results, started_ms),
         :ok <- JSONL.finish(sink, summary) do
      {:ok, summary}
    else
      {:error, reason} -> {:error, :execution, reason}
    end
  end

  defp safe_engine_run(engine, cell, opts) do
    case engine.run(cell, opts) do
      %{} = result -> result
      result -> engine_error(cell, {:invalid_engine_result, result})
    end
  rescue
    exception -> engine_error(cell, exception)
  catch
    kind, reason -> engine_error(cell, {kind, reason})
  end

  defp engine_error(cell, reason) do
    Result.new(cell,
      execution: %{
        status: :error,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        duration_ms: 0,
        turn_count: 0
      },
      evaluation: Result.evaluation([], :error),
      turns: [],
      usage: %{},
      error: Result.error(reason)
    )
  end

  defp emit_results(stream, sink, results) do
    Enum.reduce_while(stream, {:ok, results}, fn
      {:ok, result}, {:ok, acc} ->
        case JSONL.emit(sink, result) do
          :ok -> {:cont, {:ok, [result | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:exit, reason}, {:ok, _acc} ->
        {:halt, {:error, {:automation_task_exit, reason}}}
    end)
    |> case do
      {:ok, emitted} -> {:ok, Enum.reverse(emitted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp summary(plan, results, started_ms) do
    counts =
      Enum.reduce(
        results,
        %{passed: 0, failed: 0, errors: 0, unscored: 0},
        &count_result/2
      )

    status = if counts.failed == 0 and counts.errors == 0, do: :passed, else: :failed

    %{
      schema: "jido.run-summary",
      schema_version: 1,
      run_id: plan.run_id,
      suite_id: plan.suite_id,
      status: status,
      planned: length(plan.cells),
      completed: length(results),
      counts: counts,
      duration_ms: max(System.monotonic_time(:millisecond) - started_ms, 0)
    }
  end

  defp count_result(result, counts) do
    execution = get_in(result, [:execution, :status])
    evaluation = get_in(result, [:evaluation, :status])

    cond do
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
end
