defmodule Jido.Cli.Automation.Result do
  @moduledoc "Builds the stable JSONL result contract for one run cell."

  @schema "jido.case-result"
  @schema_version 1

  @doc "Builds one result record."
  @spec new(map(), keyword()) :: map()
  def new(cell, attrs) do
    %{
      schema: @schema,
      schema_version: @schema_version,
      type: "case.result",
      run_id: cell.run_id,
      cell_id: cell.cell_id,
      sequence: cell.sequence,
      dimensions: cell.dimensions,
      sources: cell.sources,
      execution: Keyword.fetch!(attrs, :execution),
      evaluation: Keyword.fetch!(attrs, :evaluation),
      turns: Keyword.get(attrs, :turns, []),
      usage: Keyword.get(attrs, :usage, %{}),
      error: Keyword.get(attrs, :error)
    }
  end

  @doc "Returns a portable error map."
  @spec error(term()) :: map()
  def error(reason) do
    reason
    |> Jidoka.normalize_error(operation: :automation)
    |> Jidoka.error_to_map()
    |> portable_term()
  rescue
    exception -> %{category: "internal", message: Exception.message(exception)}
  end

  @doc "Aggregates numeric usage fields across turns."
  @spec usage([map()]) :: map()
  def usage(turns) do
    turns
    |> Enum.map(&Map.get(&1, :usage, %{}))
    |> Enum.reduce(%{}, fn usage, acc ->
      Enum.reduce(usage, acc, fn
        {key, value}, acc when is_number(value) -> Map.update(acc, key, value, &(&1 + value))
        _entry, acc -> acc
      end)
    end)
  end

  @doc "Computes the cell evaluation state from turn records."
  @spec evaluation([map()], atom()) :: map()
  def evaluation(_turns, execution_status) when execution_status != :ok do
    %{status: :not_run, assertion_count: 0, failed_assertion_count: 0}
  end

  def evaluation(turns, :ok) do
    assertions = Enum.flat_map(turns, &get_in(&1, [:evaluation, :assertions]))
    failed = Enum.count(assertions, &(Map.get(&1, :status) == :failed))

    status =
      cond do
        assertions == [] -> :unscored
        failed > 0 -> :failed
        true -> :passed
      end

    %{
      status: status,
      assertion_count: length(assertions),
      failed_assertion_count: failed
    }
  end

  defp portable_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp portable_term(value) when is_atom(value), do: Atom.to_string(value)
  defp portable_term(value) when is_tuple(value), do: value |> Tuple.to_list() |> portable_term()
  defp portable_term(value) when is_list(value), do: Enum.map(value, &portable_term/1)

  defp portable_term(%{__struct__: _struct} = value) do
    value
    |> Map.from_struct()
    |> portable_term()
  end

  defp portable_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {portable_key(key), portable_term(item)} end)
  end

  defp portable_term(value), do: inspect(value)

  defp portable_key(key) when is_binary(key) or is_atom(key), do: key
  defp portable_key(key), do: inspect(key)
end
