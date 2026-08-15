defmodule Jido.Console.Automation.Limits do
  @moduledoc "Trusted automation ceilings, provider admission, and portable limit evidence."

  alias Jidoka.Runtime.Limits, as: RuntimeLimits

  @integer_keys [
    :max_cells,
    :max_turns_per_cell,
    :cell_timeout_ms,
    :suite_timeout_ms,
    :max_total_tokens
  ]
  @number_keys [:max_total_cost]
  @keys @integer_keys ++ @number_keys ++ [:provider_concurrency]
  @default_ceiling %{
    max_cells: 10_000,
    max_turns_per_cell: 100,
    cell_timeout_ms: 300_000,
    suite_timeout_ms: 3_600_000,
    max_total_tokens: 10_000_000,
    max_total_cost: 1_000.0
  }

  @type t :: %{
          requested: map(),
          applied: map(),
          cancel_active_on_stop: boolean()
        }

  @doc "Resolves data requests under trusted host ceilings and checks matrix size."
  @spec resolve(map(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(suite, variant_count, opts) when is_map(suite) and is_integer(variant_count) do
    requested = Map.get(suite, :limits, %{})
    defaults = Map.put(@default_ceiling, :provider_concurrency, %{"*" => suite.jobs})

    with {:ok, requested} <- normalize(requested, :requested),
         {:ok, ceiling} <- trusted_ceiling(defaults, opts),
         :ok <- within_ceiling(requested, ceiling),
         applied = merge_requested(ceiling, requested),
         :ok <- validate_plan(suite, variant_count, applied) do
      {:ok,
       %{
         requested: requested,
         applied: applied,
         cancel_active_on_stop: Keyword.get(opts, :cancel_active_on_limit, false) == true
       }}
    end
  end

  @doc "Returns public planning evidence."
  @spec manifest(t()) :: map()
  def manifest(limits) do
    %{
      status: :configured,
      requested: limits.requested,
      applied: limits.applied,
      observed: empty_observed(),
      exceeded: nil
    }
  end

  @doc "Returns the model provider key used for admission."
  @spec provider_key(map()) :: String.t()
  def provider_key(cell) do
    cell
    |> get_in([:dimensions, :model_ref])
    |> to_string()
    |> String.split([":", "/"], parts: 2)
    |> hd()
    |> case do
      "" -> "unknown"
      provider -> provider
    end
  end

  @doc "Returns the applied provider concurrency for one cell."
  @spec provider_limit(t(), map()) :: pos_integer()
  def provider_limit(limits, cell) do
    providers = limits.applied.provider_concurrency
    Map.get(providers, provider_key(cell)) || Map.get(providers, "*") || 1
  end

  @doc "Returns the Jidoka limits that apply inside one cell."
  @spec jidoka(t()) :: map()
  def jidoka(limits) do
    %{
      max_model_turns: limits.applied.max_turns_per_cell,
      turn_timeout_ms: limits.applied.cell_timeout_ms,
      capability_timeout_ms: limits.applied.cell_timeout_ms,
      sequence_timeout_ms: limits.applied.cell_timeout_ms,
      max_total_tokens: limits.applied.max_total_tokens,
      max_total_cost: limits.applied.max_total_cost
    }
  end

  @doc "Returns the cell wait limit in milliseconds."
  @spec cell_timeout_ms(t()) :: pos_integer()
  def cell_timeout_ms(limits), do: limits.applied.cell_timeout_ms

  @doc "Returns a run stop reason after a deadline or usage budget is reached."
  @spec stop_reason(t(), [map()], non_neg_integer()) :: map() | nil
  def stop_reason(limits, results, duration_ms) do
    observed = observed(results, duration_ms)

    cond do
      duration_ms >= limits.applied.suite_timeout_ms ->
        exceeded(:suite_timeout, limits.applied.suite_timeout_ms, duration_ms)

      observed.total_tokens > limits.applied.max_total_tokens ->
        exceeded(:total_tokens, limits.applied.max_total_tokens, observed.total_tokens)

      observed.total_cost > limits.applied.max_total_cost ->
        exceeded(:total_cost, limits.applied.max_total_cost, observed.total_cost)

      true ->
        nil
    end
  end

  @doc "Returns a bounded receive wait while a suite deadline is active."
  @spec receive_timeout(t(), non_neg_integer()) :: pos_integer()
  def receive_timeout(limits, duration_ms) do
    limits.applied.suite_timeout_ms
    |> Kernel.-(duration_ms)
    |> max(1)
    |> min(100)
  end

  @doc "Builds case-result limit evidence from Jidoka evidence or a local error."
  @spec result(t(), RuntimeLimits.Evidence.t() | nil, map(), map(), term()) :: map()
  def result(limits, jidoka, execution, usage, error) do
    applied = cell_applied(limits.applied, jidoka)
    observed = cell_observed(jidoka, execution, usage)
    exceeded = jidoka_exceeded(jidoka) || local_exceeded(error, applied, execution)

    %{
      status: if(exceeded, do: :exceeded, else: :within),
      requested: limits.requested,
      applied: applied,
      observed: observed,
      exceeded: exceeded
    }
  end

  @doc "Builds final suite limit evidence."
  @spec summary(t(), map(), non_neg_integer()) :: map()
  def summary(limits, outcome, duration_ms) do
    exceeded = outcome.limit_stop || stop_reason(limits, outcome.results, duration_ms)

    %{
      status: if(exceeded, do: :exceeded, else: :within),
      requested: limits.requested,
      applied: limits.applied,
      observed: observed(outcome.results, duration_ms),
      exceeded: exceeded
    }
  end

  defp trusted_ceiling(defaults, opts) do
    case Keyword.get(opts, :automation_limit_ceiling, %{}) do
      attrs when is_map(attrs) or is_list(attrs) ->
        with {:ok, values} <- normalize(attrs, :ceiling) do
          {:ok, merge_ceiling(defaults, values)}
        end

      other ->
        {:error, {:invalid_automation_limit_ceiling, other}}
    end
  end

  defp merge_ceiling(defaults, values) do
    providers = Map.merge(defaults.provider_concurrency, Map.get(values, :provider_concurrency, %{}))

    values
    |> Map.delete(:provider_concurrency)
    |> then(&Map.merge(defaults, &1))
    |> Map.put(:provider_concurrency, providers)
  end

  defp merge_requested(ceiling, requested) do
    providers = Map.merge(ceiling.provider_concurrency, requested.provider_concurrency)

    requested
    |> Map.delete(:provider_concurrency)
    |> then(&Map.merge(ceiling, &1))
    |> Map.put(:provider_concurrency, providers)
  end

  defp normalize(attrs, kind) do
    attrs = attrs |> Map.new() |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    unknown = Map.keys(attrs) -- @keys

    with [] <- unknown,
         :ok <- validate_positive(attrs, @integer_keys, &is_integer/1),
         :ok <- validate_positive(attrs, @number_keys, &is_number/1),
         {:ok, providers} <- providers(Map.get(attrs, :provider_concurrency, %{})) do
      {:ok, Map.put(attrs, :provider_concurrency, providers)}
    else
      values when is_list(values) -> {:error, {:unknown_automation_limit_keys, kind, Enum.sort(values)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, {:invalid_automation_limits, kind, attrs}}
  end

  defp validate_positive(attrs, keys, predicate) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Map.fetch(attrs, key) do
        :error -> {:cont, :ok}
        {:ok, value} when value > 0 -> if(predicate.(value), do: {:cont, :ok}, else: {:halt, invalid(key, value)})
        {:ok, value} -> {:halt, invalid(key, value)}
      end
    end)
  end

  defp invalid(key, value), do: {:error, {:invalid_automation_limit, key, value}}

  defp providers(providers) when is_map(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn {provider, value}, {:ok, acc} ->
      provider = to_string(provider)

      if provider != "" and is_integer(value) and value > 0 do
        {:cont, {:ok, Map.put(acc, provider, value)}}
      else
        {:halt, {:error, {:invalid_provider_concurrency, provider, value}}}
      end
    end)
  end

  defp providers(other), do: {:error, {:invalid_provider_concurrency, other}}

  defp within_ceiling(requested, ceiling) do
    scalar_error =
      Enum.find_value(@integer_keys ++ @number_keys, fn key ->
        requested_value = Map.get(requested, key)
        ceiling_value = Map.get(ceiling, key)

        if requested_value && requested_value > ceiling_value,
          do: {:automation_limit_exceeds_ceiling, key, requested_value, ceiling_value}
      end)

    provider_error =
      Enum.find_value(requested.provider_concurrency, fn {provider, value} ->
        ceiling_value = Map.get(ceiling.provider_concurrency, provider, ceiling.provider_concurrency["*"])
        if value > ceiling_value, do: {:provider_concurrency_exceeds_ceiling, provider, value, ceiling_value}
      end)

    case scalar_error || provider_error do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp validate_plan(suite, variant_count, applied) do
    cell_count = variant_count * length(suite.scenarios) * suite.repeats
    longest = suite.scenarios |> Enum.map(&length(&1.turns)) |> Enum.max(fn -> 0 end)

    cond do
      cell_count > applied.max_cells ->
        {:error, {:automation_matrix_limit_exceeded, cell_count, applied.max_cells}}

      longest > applied.max_turns_per_cell ->
        {:error, {:automation_turn_limit_exceeded, longest, applied.max_turns_per_cell}}

      true ->
        :ok
    end
  end

  defp observed(results, duration_ms) do
    usage = aggregate_usage(results)

    %{
      cells: length(results),
      turns: Enum.reduce(results, 0, &(&2 + get_in(&1, [:execution, :turn_count]))),
      duration_ms: duration_ms,
      total_tokens: numeric(usage, :total_tokens),
      total_cost: numeric(usage, :total_cost)
    }
  end

  defp cell_observed(%RuntimeLimits.Evidence{observed: observed}, execution, usage) do
    %{
      cells: 1,
      turns: execution.turn_count,
      duration_ms: execution.duration_ms,
      total_tokens: numeric(observed.usage, :total_tokens),
      total_cost: numeric(observed.usage, :total_cost)
    }
    |> fallback_usage(usage)
  end

  defp cell_observed(_jidoka, execution, usage) do
    %{
      cells: 1,
      turns: execution.turn_count,
      duration_ms: execution.duration_ms,
      total_tokens: numeric(usage, :total_tokens),
      total_cost: numeric(usage, :total_cost)
    }
  end

  defp cell_applied(applied, %RuntimeLimits.Evidence{applied: jidoka}) do
    %{
      applied
      | max_turns_per_cell: jidoka.max_model_turns,
        cell_timeout_ms: jidoka.sequence_timeout_ms || jidoka.turn_timeout_ms,
        max_total_tokens: jidoka.max_total_tokens || applied.max_total_tokens,
        max_total_cost: jidoka.max_total_cost || applied.max_total_cost
    }
  end

  defp cell_applied(applied, _jidoka), do: applied

  defp fallback_usage(observed, usage) do
    observed
    |> Map.update!(:total_tokens, &if(&1 == 0, do: numeric(usage, :total_tokens), else: &1))
    |> Map.update!(:total_cost, &if(&1 == 0, do: numeric(usage, :total_cost), else: &1))
  end

  defp aggregate_usage(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      Enum.reduce(result.usage, acc, fn
        {key, value}, usage when is_number(value) -> Map.update(usage, key, value, &(&1 + value))
        _entry, usage -> usage
      end)
    end)
  end

  defp jidoka_exceeded(%RuntimeLimits.Evidence{exceeded: %RuntimeLimits.Exceeded{} = exceeded}) do
    exceeded(exceeded.kind, exceeded.limit, exceeded.observed)
  end

  defp jidoka_exceeded(_jidoka), do: nil

  defp local_exceeded(error, applied, execution) do
    cond do
      timeout_error?(error) ->
        exceeded(:cell_timeout, applied.cell_timeout_ms, execution.duration_ms)

      execution.duration_ms >= applied.cell_timeout_ms ->
        exceeded(:cell_timeout, applied.cell_timeout_ms, execution.duration_ms)

      true ->
        nil
    end
  end

  defp timeout_error?(:timeout), do: true
  defp timeout_error?({:error, reason}), do: timeout_error?(reason)
  defp timeout_error?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.any?(&timeout_error?/1)
  defp timeout_error?(value) when is_list(value), do: Enum.any?(value, &timeout_error?/1)
  defp timeout_error?(_value), do: false

  defp exceeded(kind, limit, observed), do: %{kind: kind, limit: limit, observed: observed}

  defp empty_observed, do: %{cells: 0, turns: 0, duration_ms: 0, total_tokens: 0, total_cost: 0}

  defp numeric(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_number(value) -> value
      _value -> 0
    end
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Enum.find(@keys, key, &(Atom.to_string(&1) == key))
  defp normalize_key(key), do: key
end
