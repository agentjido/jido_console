defmodule Jido.Console.Automation.Result do
  @moduledoc "Builds the stable JSONL result contract for one run cell."

  alias Jido.Console.Automation.{
    Contract,
    EnvironmentProjection,
    Limits,
    ReplayProjection,
    ResultValue
  }

  @schema "jido.case-result"
  @schema_version 1

  @doc "Builds one result record."
  @spec new(map(), keyword()) :: map()
  def new(cell, attrs) do
    execution = Keyword.fetch!(attrs, :execution)
    usage = Keyword.get(attrs, :usage, %{})

    values = %{
      schema: @schema,
      schema_version: @schema_version,
      type: "case.result",
      run_id: cell.run_id,
      cell_id: cell.cell_id,
      sequence: cell.sequence,
      dimensions: cell.dimensions,
      sources: cell.sources,
      execution: execution,
      execution_environment:
        execution_environment(
          cell,
          Keyword.get(attrs, :environment),
          Keyword.get(attrs, :environment_error)
        ),
      capability_replay: Keyword.get(attrs, :capability_replay, replay_projection(cell)),
      evaluation: Keyword.fetch!(attrs, :evaluation),
      turns: Keyword.get(attrs, :turns, []),
      usage: usage,
      error: Keyword.get(attrs, :error),
      extensions: result_extensions(cell, Keyword.get(attrs, :extensions, %{}))
    }

    values = maybe_put_runtime_limits(values, cell, attrs, execution, usage)
    Contract.case_result!(values)
  end

  @doc "Projects requested, resolved, and confirmed environment facts."
  @spec execution_environment(map(), term(), term()) :: map()
  def execution_environment(cell, environment \\ nil, error \\ nil),
    do: EnvironmentProjection.project(cell, environment, error)

  @doc "Returns a portable error map."
  defdelegate error(reason), to: ResultValue

  @doc "Aggregates numeric usage fields across turns."
  defdelegate usage(turns), to: ResultValue

  @doc "Computes the cell evaluation state from turn records."
  defdelegate evaluation(turns, execution_status), to: ResultValue

  defp maybe_put_runtime_limits(values, cell, attrs, execution, usage) do
    case Map.get(cell, :runtime_limits) do
      nil ->
        values

      limits ->
        evidence =
          Limits.result(
            limits,
            Keyword.get(attrs, :runtime_limit_evidence),
            execution,
            usage,
            Keyword.get(attrs, :runtime_limit_error, Keyword.get(attrs, :error))
          )

        Map.put(values, :runtime_limits, evidence)
    end
  end

  defp result_extensions(cell, values) do
    trust =
      cell
      |> Map.get(:extensions, Jido.Console.Extensions.Setup.not_requested())
      |> Jido.Console.Extensions.Setup.projection()

    Map.put(values, "jido.cli.trust", trust)
  end

  defp replay_projection(cell) do
    cell
    |> Map.get(:capability_replay, %{mode: :live})
    |> ReplayProjection.projection()
  end
end
