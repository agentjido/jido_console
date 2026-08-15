defmodule Jido.Console.Automation.Loader.SuiteEntries do
  @moduledoc false

  import Jido.Console.Automation.Loader.Fields

  @doc false
  @spec agents(map(), Path.t()) :: {:ok, [map()]} | {:error, term()}
  def agents(suite, base_dir) do
    case Map.get(suite, "agents") do
      agents when is_list(agents) and agents != [] ->
        agents
        |> Enum.reduce_while({:ok, []}, fn agent, {:ok, acc} ->
          case agent(agent, base_dir) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> reverse_result()

      agents ->
        {:error, {:invalid_suite_agents, agents}}
    end
  end

  @doc false
  @spec scenarios(map(), Path.t(), keyword(), (Path.t(), keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def scenarios(suite, base_dir, opts, load_scenario) do
    case Map.get(suite, "scenarios") do
      scenarios when is_list(scenarios) and scenarios != [] ->
        scenarios
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          with {:ok, file} <- scenario_file(entry),
               {:ok, scenario} <- load_scenario.(resolve_path(base_dir, file), opts) do
            {:cont, {:ok, [scenario | acc]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> reverse_result()

      scenarios ->
        {:error, {:invalid_suite_scenarios, scenarios}}
    end
  end

  @doc false
  @spec models(map()) :: {:ok, [map()]} | {:error, term()}
  def models(suite) do
    case Map.get(suite, "models") do
      nil ->
        {:ok, [%{key: "declared", source: :agent, ref: nil, generation: nil}]}

      models when is_list(models) and models != [] ->
        models
        |> Enum.reduce_while({:ok, []}, fn model, {:ok, acc} ->
          case model(model) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> reverse_result()

      models ->
        {:error, {:invalid_suite_models, models}}
    end
  end

  defp agent(file, base_dir) when is_binary(file) do
    path = resolve_path(base_dir, file)
    {:ok, %{key: path |> Path.basename() |> Path.rootname() |> key(), file: path}}
  end

  defp agent(agent, base_dir) when is_map(agent) do
    with :ok <- reject_execution_controls(agent),
         {:ok, file} <- required_string(agent, "file"),
         path = resolve_path(base_dir, file),
         {:ok, key} <- optional_id(Map.get(agent, "key"), path |> Path.basename() |> Path.rootname() |> key()) do
      {:ok, %{key: key, file: path}}
    end
  end

  defp agent(agent, _base_dir), do: {:error, {:invalid_suite_agent, agent}}

  defp scenario_file(file) when is_binary(file), do: {:ok, file}
  defp scenario_file(%{"file" => file}) when is_binary(file) and file != "", do: {:ok, file}
  defp scenario_file(entry), do: {:error, {:invalid_scenario_reference, entry}}

  defp model(model) when is_binary(model) and model != "" do
    {:ok, %{key: key(model), source: :override, ref: model, generation: nil}}
  end

  defp model(model) when is_map(model) do
    source = Map.get(model, "source")
    ref = Map.get(model, "ref")

    cond do
      source == "agent" ->
        with {:ok, key} <- optional_id(Map.get(model, "key"), "declared") do
          {:ok, %{key: key, source: :agent, ref: nil, generation: nil}}
        end

      is_binary(ref) and ref != "" ->
        with {:ok, key} <- optional_id(Map.get(model, "key"), key(ref)),
             {:ok, generation} <- optional_map(Map.get(model, "generation")) do
          {:ok, %{key: key, source: :override, ref: ref, generation: generation}}
        end

      true ->
        {:error, {:invalid_suite_model, model}}
    end
  end

  defp model(model), do: {:error, {:invalid_suite_model, model}}
end
