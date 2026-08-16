defmodule Jido.Console.Automation.Loader.SuiteEntries do
  @moduledoc false

  import Jido.Console.Automation.Loader.Fields

  @doc false
  @spec reject_agent_execution_controls(map()) :: :ok | {:error, term()}
  def reject_agent_execution_controls(suite) do
    case Map.get(suite, "agents") do
      agents when is_list(agents) ->
        Enum.reduce_while(agents, :ok, fn
          agent, :ok when is_map(agent) ->
            case reject_execution_controls(agent) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _agent, :ok ->
            {:cont, :ok}
        end)

      _agents ->
        :ok
    end
  end

  @doc false
  @spec agents(map(), Path.t()) :: {:ok, [map()]} | {:error, term()}
  def agents(suite, base_dir) do
    agents = Enum.map(Map.fetch!(suite, "agents"), &agent(&1, base_dir))
    {:ok, agents}
  end

  @doc false
  @spec scenarios(map(), Path.t(), keyword(), (Path.t(), keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def scenarios(suite, base_dir, opts, load_scenario) do
    suite
    |> Map.fetch!("scenarios")
    |> Enum.reduce_while({:ok, []}, fn {:file, file}, {:ok, acc} ->
      case load_scenario.(resolve_path(base_dir, file), opts) do
        {:ok, scenario} -> {:cont, {:ok, [scenario | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  @doc false
  @spec models(map()) :: {:ok, [map()]} | {:error, term()}
  def models(suite) do
    case Map.get(suite, "models") do
      nil ->
        {:ok, [%{key: "declared", source: :agent, ref: nil, generation: nil}]}

      models ->
        {:ok, Enum.map(models, &model/1)}
    end
  end

  defp agent({:file, file, nil}, base_dir) do
    path = resolve_path(base_dir, file)
    %{key: path |> Path.basename() |> Path.rootname() |> key(), file: path}
  end

  defp agent({:file, file, key}, base_dir) do
    %{key: key, file: resolve_path(base_dir, file)}
  end

  defp model({:agent, nil}) do
    %{key: "declared", source: :agent, ref: nil, generation: nil}
  end

  defp model({:agent, key}) do
    %{key: key, source: :agent, ref: nil, generation: nil}
  end

  defp model({:override, ref, nil, generation}) do
    %{key: key(ref), source: :override, ref: ref, generation: generation}
  end

  defp model({:override, ref, key, generation}) do
    %{key: key, source: :override, ref: ref, generation: generation}
  end
end
