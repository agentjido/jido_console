defmodule Jido.Console.Automation.Loader do
  @moduledoc "Loads agent, scenario, and suite files for automated runs."

  alias Jido.Console.Digest
  alias Jido.Console.Automation.InputSchema
  alias Jido.Console.Automation.Loader.{Source, SuiteEntries}
  import Jido.Console.Automation.Loader.Fields

  @doc "Loads one version 1 suite and all referenced scenarios."
  @spec load_suite(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_suite(path, opts \\ []) do
    path = Path.expand(path)

    with {:ok, document, contents} <- Source.decode_file(path, opts),
         :ok <- version_one(document, path),
         raw_suite = Map.get(document, "suite"),
         :ok <- reject_execution_controls(raw_suite),
         :ok <- SuiteEntries.reject_agent_execution_controls(raw_suite),
         raw_run = section_value(raw_suite, "run"),
         :ok <- reject_execution_controls(raw_run),
         {:ok, document} <- InputSchema.validate_suite(document, path),
         suite = Map.fetch!(document, "suite"),
         id = Map.fetch!(suite, "id"),
         run = Map.get(suite, "run", %{}),
         limits = Map.get(run, "limits", %{}),
         execution_profile = Map.get(run, "execution_profile"),
         {:ok, agents} <- SuiteEntries.agents(suite, Path.dirname(path)),
         {:ok, scenarios} <- SuiteEntries.scenarios(suite, Path.dirname(path), opts, &load_scenario/2),
         {:ok, models} <- SuiteEntries.models(suite),
         repeats = matrix_value(suite, "repeats", 1),
         jobs = run_value(suite, "jobs", 1),
         output = output_path(run_value(suite, "output", nil), Path.dirname(path)),
         :ok <- unique_values(agents, :key, :agent),
         :ok <- unique_values(scenarios, :id, :scenario),
         :ok <- unique_values(models, :key, :model) do
      {:ok,
       %{
         id: id,
         path: path,
         digest: digest(contents),
         agents: agents,
         scenarios: scenarios,
         models: models,
         repeats: repeats,
         jobs: jobs,
         limits: limits,
         execution_profile: execution_profile,
         command_execution_profile: nil,
         output: output
       }}
    end
  end

  @doc "Loads one version 1 scenario."
  @spec load_scenario(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_scenario(path, opts \\ []) do
    path = Path.expand(path)

    with {:ok, document, contents} <- Source.decode_file(path, opts),
         :ok <- version_one(document, path),
         raw_scenario = Map.get(document, "scenario"),
         :ok <- reject_execution_controls(raw_scenario),
         {:ok, document} <- InputSchema.validate_scenario(document, path),
         scenario = Map.fetch!(document, "scenario"),
         id = Map.fetch!(scenario, "id"),
         execution_profile = Map.get(scenario, "execution_profile"),
         {:ok, context} <- Source.data(Map.get(scenario, "context"), Path.dirname(path), opts),
         {:ok, turns} <- scenario_turns(scenario, context, path, opts),
         :ok <- unique_values(turns, :id, :turn) do
      {:ok,
       %{
         id: id,
         path: path,
         digest: digest(contents),
         tags: Map.get(scenario, "tags", []),
         execution_profile: execution_profile,
         turns: turns
       }}
    end
  end

  @doc "Builds a one-turn scenario from a text file or standard input."
  @spec scenario_from_input(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def scenario_from_input(input, opts \\ []) do
    with {:ok, text, path} <- Source.input_text(input, opts) do
      id = if path == "-", do: "stdin", else: path |> Path.basename() |> Path.rootname() |> key()

      {:ok,
       %{
         id: id,
         path: path,
         digest: digest(text),
         tags: [],
         execution_profile: nil,
         turns: [%{id: "turn-1", input: text, context: %{}, assertions: %{}}]
       }}
    end
  end

  @doc "Imports one Jidoka agent document from a file."
  @spec load_agent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_agent(path, import_opts \\ []) do
    path = Path.expand(path)

    with {:ok, contents} <- Source.read_text(path, import_opts),
         {:ok, spec} <- Jidoka.import(contents, import_opts) do
      {:ok, %{spec: spec, path: path, digest: digest(contents)}}
    else
      {:error, reason} -> {:error, {:agent_load_failed, path, reason}}
    end
  end

  @doc "Returns a SHA-256 digest as lower-case hexadecimal text."
  @spec digest(binary()) :: String.t()
  def digest(value) when is_binary(value) do
    Digest.hex(value)
  end

  defp scenario_turns(%{"turns" => turns}, common_context, path, opts) do
    turns
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {turn, index}, {:ok, acc} ->
      case normalize_turn(turn, index, common_context, Path.dirname(path), opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_turn, path, index, reason}}}
      end
    end)
    |> reverse_result()
  end

  defp normalize_turn(turn, index, common_context, base_dir, opts) do
    with {:ok, input} <- Source.text(Map.fetch!(turn, "input"), base_dir, opts),
         {:ok, context} <- Source.data(Map.get(turn, "context"), base_dir, opts) do
      {:ok,
       %{
         id: Map.get(turn, "id", "turn-#{index}"),
         input: input,
         context: Map.merge(common_context, context),
         assertions: normalize_assertions(Map.get(turn, "assertions", %{}))
       }}
    end
  end

  defp normalize_assertions(assertions) do
    %{}
    |> maybe_put(:contains, Map.get(assertions, "contains"))
    |> maybe_put(:equals, Map.get(assertions, "equals"))
    |> maybe_put(:operation_called, Map.get(assertions, "operation_called"))
  end

  defp section_value(section, key) when is_map(section), do: Map.get(section, key)
  defp section_value(_section, _key), do: nil

  defp output_path(nil, _base_dir), do: nil
  defp output_path(path, base_dir), do: resolve_path(base_dir, path)
end
