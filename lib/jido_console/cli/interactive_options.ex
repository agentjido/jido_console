defmodule Jido.Console.InteractiveOptions do
  @moduledoc "Validated interactive command options."

  alias Jido.Console.ExecutionPolicy

  @schema Zoi.map(
            %{
              agent_source: Zoi.string() |> Zoi.optional(),
              coding_pack: Zoi.string() |> Zoi.optional(),
              deprecation_warnings: Zoi.array(Zoi.string()) |> Zoi.optional(),
              execution_policy: Zoi.string() |> Zoi.optional(),
              execution_policy_direct_choice: Zoi.any() |> Zoi.optional(),
              help: Zoi.boolean() |> Zoi.optional(),
              model: Zoi.string() |> Zoi.optional(),
              model_origin: Zoi.literal(:cli) |> Zoi.optional(),
              project_root: Zoi.string() |> Zoi.optional(),
              version: Zoi.boolean() |> Zoi.optional()
            },
            unrecognized_keys: :error
          )

  @allowed_keys [
    :agent,
    :coding_pack,
    :coding_profile,
    :execution_policy,
    :help,
    :model,
    :project_root,
    :version
  ]

  @doc "Validates options returned by `OptionParser`."
  @spec parse(keyword()) :: {:ok, map()} | {:error, term()}
  def parse(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         :ok <- validate_keys(options),
         :ok <- validate_repeats(options),
         {:ok, direct_choice} <- ExecutionPolicy.direct_choice(options, :cli),
         normalized <- normalize(options, direct_choice) do
      case Zoi.parse(@schema, normalized) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, errors} -> invalid(Zoi.treefy_errors(errors))
      end
    else
      false -> invalid(:not_a_keyword_list)
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_options), do: invalid(:not_a_keyword_list)

  defp validate_keys(options) do
    case Enum.find(options, fn {key, _value} -> key not in @allowed_keys end) do
      nil -> :ok
      {key, _value} -> invalid({:unknown_key, key})
    end
  end

  defp validate_repeats(options) do
    case Enum.find(@allowed_keys, &(length(Keyword.get_values(options, &1)) > 1)) do
      nil -> :ok
      key -> {:error, {:repeated_interactive_option, key}}
    end
  end

  defp normalize(options, direct_choice) do
    options
    |> Map.new()
    |> rename(:agent, :agent_source)
    |> Map.delete(:coding_profile)
    |> put_policy(direct_choice)
    |> put_model_origin()
    |> put_warnings(options)
  end

  defp put_policy(map, nil), do: map

  defp put_policy(map, direct_choice) do
    map
    |> Map.put(:execution_policy, direct_choice.execution_policy_id)
    |> Map.put(:execution_policy_direct_choice, direct_choice)
  end

  defp put_model_origin(%{model: _model} = map), do: Map.put(map, :model_origin, :cli)
  defp put_model_origin(map), do: map

  defp put_warnings(map, options) do
    if Keyword.has_key?(options, :coding_profile) do
      Map.put(map, :deprecation_warnings, [ExecutionPolicy.legacy_warning()])
    else
      map
    end
  end

  defp rename(map, from, to) do
    case Map.pop(map, from) do
      {nil, map} -> map
      {value, map} -> Map.put(map, to, value)
    end
  end

  defp invalid(details), do: {:error, {:invalid_interactive_options, details}}
end
