defmodule Jido.Cli.Automation do
  @moduledoc "Runs file-based Jido scenarios and evaluation suites."

  alias Jido.Cli.Automation.{Command, Contract, Coordinator, Interrupt, JSONL, Loader, Plan}

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
      jobs = command.jobs || suite.jobs
      {:ok, %{suite | jobs: jobs, command_execution_profile: Map.get(command, :runtime_profile)}}
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
            file: agent_path
          }
        ],
        scenarios: [scenario],
        models: models,
        repeats: 1,
        jobs: 1,
        execution_profile: nil,
        command_execution_profile: Map.get(command, :runtime_profile),
        output: Map.get(command, :output)
      }

      {:ok, suite}
    end
  end

  defp command_scenario(%{scenario: scenario, input: nil}, opts) when is_binary(scenario),
    do: Loader.load_scenario(scenario, opts)

  defp command_scenario(%{input: input, scenario: nil}, opts) when is_binary(input),
    do: Loader.scenario_from_input(input, opts)

  defp run(plan, sink, command, opts) do
    started_ms = System.monotonic_time(:millisecond)
    jobs = if command.name == :eval, do: plan.suite.jobs, else: 1
    engine = Keyword.get(opts, :engine, Jido.Cli.Automation.Engine.Jidoka)

    case Interrupt.start(self(), opts) do
      {:ok, interrupt} ->
        try do
          with {:ok, outcome} <- Coordinator.run(plan.cells, sink, engine, jobs, opts),
               summary <- summary(plan, outcome, started_ms),
               :ok <- JSONL.finish(sink, summary) do
            {:ok, summary}
          else
            {:error, reason} -> {:error, :execution, reason}
          end
        after
          Interrupt.stop(interrupt)
        end

      {:error, reason} ->
        {:error, :execution, reason}
    end
  end

  defp summary(plan, outcome, started_ms) do
    results = outcome.results

    counts =
      Enum.reduce(
        results,
        %{passed: 0, failed: 0, errors: 0, unscored: 0, cancelled: 0},
        &count_result/2
      )

    status =
      cond do
        outcome.cancelled? -> :cancelled
        counts.failed == 0 and counts.errors == 0 -> :passed
        true -> :failed
      end

    Contract.summary!(%{
      schema: "jido.run-summary",
      schema_version: 1,
      run_id: plan.run_id,
      suite_id: plan.suite_id,
      status: status,
      planned: length(plan.cells),
      completed: length(results),
      counts: counts,
      duration_ms: max(System.monotonic_time(:millisecond) - started_ms, 0),
      not_started: Enum.map(outcome.not_started, & &1.cell_id)
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
end
