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
         {:ok, suite} <- required_map(document, "suite", path),
         {:ok, id} <- required_id(suite, "id", path),
         :ok <- reject_execution_controls(suite),
         {:ok, run} <- optional_section(suite, "run"),
         :ok <- reject_execution_controls(run),
         {:ok, limits} <- optional_section(run, "limits"),
         {:ok, execution_profile} <- optional_profile(Map.get(run, "execution_profile")),
         {:ok, agents} <- SuiteEntries.agents(suite, Path.dirname(path)),
         {:ok, scenarios} <- SuiteEntries.scenarios(suite, Path.dirname(path), opts, &load_scenario/2),
         {:ok, models} <- SuiteEntries.models(suite),
         {:ok, repeats} <- positive_integer(matrix_value(suite, "repeats", 1), :repeats),
         {:ok, jobs} <- positive_integer(run_value(suite, "jobs", 1), :jobs),
         {:ok, output} <- optional_output(run_value(suite, "output", nil), Path.dirname(path)),
         {:ok, _validated_document} <- InputSchema.validate_suite(document, path),
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
         {:ok, scenario} <- required_map(document, "scenario", path),
         {:ok, id} <- required_id(scenario, "id", path),
         :ok <- reject_execution_controls(scenario),
         {:ok, execution_profile} <- optional_profile(Map.get(scenario, "execution_profile")),
         {:ok, context} <- Source.data(Map.get(scenario, "context"), Path.dirname(path), opts),
         {:ok, turns} <- scenario_turns(scenario, context, path, opts),
         {:ok, _validated_document} <- InputSchema.validate_scenario(document, path),
         :ok <- unique_values(turns, :id, :turn) do
      {:ok,
       %{
         id: id,
         path: path,
         digest: digest(contents),
         tags: string_list(Map.get(scenario, "tags", [])),
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

  defp scenario_turns(%{"turns" => turns}, common_context, path, opts)
       when is_list(turns) and turns != [] do
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

  defp scenario_turns(%{"turns" => turns}, _context, path, _opts),
    do: {:error, {:invalid_turns, path, turns}}

  defp scenario_turns(%{"request" => request} = scenario, common_context, path, opts)
       when is_map(request) do
    turn = %{
      "id" => Map.get(request, "id", "turn-1"),
      "input" => Map.get(request, "input"),
      "context" => Map.get(request, "context"),
      "assertions" => Map.get(scenario, "assertions", %{})
    }

    with {:ok, normalized} <-
           normalize_turn(turn, 1, common_context, Path.dirname(path), opts) do
      {:ok, [normalized]}
    end
  end

  defp scenario_turns(_scenario, _context, path, _opts),
    do: {:error, {:missing_scenario_turns, path}}

  defp normalize_turn(turn, index, common_context, base_dir, opts) when is_map(turn) do
    request = Map.get(turn, "request", %{})
    input = Map.get(turn, "input", Map.get(request, "input"))
    turn_context = Map.get(turn, "context", Map.get(request, "context"))

    with {:ok, id} <- optional_id(Map.get(turn, "id"), "turn-#{index}"),
         {:ok, input} <- Source.text(input, base_dir, opts),
         {:ok, context} <- Source.data(turn_context, base_dir, opts),
         {:ok, assertions} <- assertions(Map.get(turn, "assertions", %{})) do
      {:ok,
       %{
         id: id,
         input: input,
         context: Map.merge(common_context, context),
         assertions: assertions
       }}
    end
  end

  defp normalize_turn(turn, _index, _context, _base_dir, _opts),
    do: {:error, {:invalid_turn, turn}}

  defp assertions(nil), do: {:ok, %{}}

  defp assertions(assertions) when is_map(assertions) do
    supported = ["contains", "equals", "operation_called"]
    unknown = assertions |> Map.keys() |> Enum.reject(&(&1 in supported))

    if unknown == [] do
      with {:ok, contains} <- string_or_list(Map.get(assertions, "contains"), :contains),
           {:ok, equals} <- optional_string(Map.get(assertions, "equals")),
           {:ok, operations} <-
             string_or_list(Map.get(assertions, "operation_called"), :operation_called) do
        result =
          %{}
          |> maybe_put(:contains, contains)
          |> maybe_put(:equals, equals)
          |> maybe_put(:operation_called, operations)

        {:ok, result}
      end
    else
      {:error, {:unsupported_assertions, unknown}}
    end
  end

  defp assertions(value), do: {:error, {:invalid_assertions, value}}
end
