defmodule Jido.Cli.Automation.Loader do
  @moduledoc "Loads agent, scenario, and suite files for automated runs."

  @default_max_bytes 1_000_000
  @forbidden_execution_keys ~w(
    execution_environment runtime_profile adapter backend command image mount mounts network
    replay fixture fixture_path fixture_json fixture_digest
  )

  @doc "Loads one version 1 suite and all referenced scenarios."
  @spec load_suite(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_suite(path, opts \\ []) do
    path = Path.expand(path)

    with {:ok, document, contents} <- decode_file(path, opts),
         :ok <- version_one(document, path),
         {:ok, suite} <- required_map(document, "suite", path),
         {:ok, id} <- required_id(suite, "id", path),
         :ok <- reject_execution_controls(suite),
         {:ok, run} <- optional_section(suite, "run"),
         :ok <- reject_execution_controls(run),
         {:ok, execution_profile} <- optional_profile(Map.get(run, "execution_profile")),
         {:ok, agents} <- suite_agents(suite, Path.dirname(path)),
         {:ok, scenarios} <- suite_scenarios(suite, Path.dirname(path), opts),
         {:ok, models} <- suite_models(suite),
         {:ok, repeats} <- positive_integer(matrix_value(suite, "repeats", 1), :repeats),
         {:ok, jobs} <- positive_integer(run_value(suite, "jobs", 1), :jobs),
         {:ok, output} <- optional_output(run_value(suite, "output", nil), Path.dirname(path)),
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

    with {:ok, document, contents} <- decode_file(path, opts),
         :ok <- version_one(document, path),
         {:ok, scenario} <- required_map(document, "scenario", path),
         {:ok, id} <- required_id(scenario, "id", path),
         :ok <- reject_execution_controls(scenario),
         {:ok, execution_profile} <- optional_profile(Map.get(scenario, "execution_profile")),
         {:ok, context} <- data_source(Map.get(scenario, "context"), Path.dirname(path), opts),
         {:ok, turns} <- scenario_turns(scenario, context, path, opts),
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
    with {:ok, text, path} <- input_text(input, opts) do
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

    with {:ok, contents} <- read_text(path, import_opts),
         {:ok, spec} <- Jidoka.import(contents, import_opts) do
      {:ok, %{spec: spec, path: path, digest: digest(contents)}}
    else
      {:error, reason} -> {:error, {:agent_load_failed, path, reason}}
    end
  end

  @doc "Returns a SHA-256 digest as lower-case hexadecimal text."
  @spec digest(binary()) :: String.t()
  def digest(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
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
         {:ok, input} <- text_source(input, base_dir, opts),
         {:ok, context} <- data_source(turn_context, base_dir, opts),
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

  defp suite_agents(suite, base_dir) do
    case Map.get(suite, "agents") do
      agents when is_list(agents) and agents != [] ->
        agents
        |> Enum.reduce_while({:ok, []}, fn agent, {:ok, acc} ->
          case suite_agent(agent, base_dir) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> reverse_result()

      agents ->
        {:error, {:invalid_suite_agents, agents}}
    end
  end

  defp suite_agent(file, base_dir) when is_binary(file) do
    path = resolve_path(base_dir, file)

    {:ok, %{key: path |> Path.basename() |> Path.rootname() |> key(), file: path}}
  end

  defp suite_agent(agent, base_dir) when is_map(agent) do
    with :ok <- reject_execution_controls(agent),
         {:ok, file} <- required_string(agent, "file"),
         path = resolve_path(base_dir, file),
         {:ok, key} <-
           optional_id(Map.get(agent, "key"), path |> Path.basename() |> Path.rootname() |> key()) do
      {:ok, %{key: key, file: path}}
    end
  end

  defp suite_agent(agent, _base_dir), do: {:error, {:invalid_suite_agent, agent}}

  defp suite_scenarios(suite, base_dir, opts) do
    case Map.get(suite, "scenarios") do
      scenarios when is_list(scenarios) and scenarios != [] ->
        scenarios
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          with {:ok, file} <- scenario_file(entry),
               {:ok, scenario} <- load_scenario(resolve_path(base_dir, file), opts) do
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

  defp scenario_file(file) when is_binary(file), do: {:ok, file}
  defp scenario_file(%{"file" => file}) when is_binary(file) and file != "", do: {:ok, file}
  defp scenario_file(entry), do: {:error, {:invalid_scenario_reference, entry}}

  defp suite_models(suite) do
    case Map.get(suite, "models") do
      nil ->
        {:ok, [%{key: "declared", source: :agent, ref: nil, generation: nil}]}

      models when is_list(models) and models != [] ->
        models
        |> Enum.reduce_while({:ok, []}, fn model, {:ok, acc} ->
          case suite_model(model) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> reverse_result()

      models ->
        {:error, {:invalid_suite_models, models}}
    end
  end

  defp suite_model(model) when is_binary(model) and model != "" do
    {:ok, %{key: key(model), source: :override, ref: model, generation: nil}}
  end

  defp suite_model(model) when is_map(model) do
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

  defp suite_model(model), do: {:error, {:invalid_suite_model, model}}

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

  defp text_source(text, _base_dir, _opts) when is_binary(text) and text != "",
    do: {:ok, text}

  defp text_source(source, base_dir, opts) when is_map(source) do
    text = Map.get(source, "text")
    file = Map.get(source, "file")

    cond do
      is_binary(text) and not is_nil(file) -> {:error, :multiple_text_sources}
      is_binary(text) and text != "" -> {:ok, text}
      is_binary(file) and file != "" -> read_text(resolve_path(base_dir, file), opts)
      true -> {:error, {:invalid_text_source, source}}
    end
  end

  defp text_source(source, _base_dir, _opts), do: {:error, {:invalid_text_source, source}}

  defp data_source(nil, _base_dir, _opts), do: {:ok, %{}}

  defp data_source(source, base_dir, opts) when is_map(source) do
    value? = Map.has_key?(source, "value")
    file = Map.get(source, "file")

    cond do
      value? and not is_nil(file) ->
        {:error, :multiple_data_sources}

      value? ->
        map_value(Map.get(source, "value"), :context)

      is_binary(file) and file != "" ->
        with {:ok, decoded, _contents} <- decode_file(resolve_path(base_dir, file), opts) do
          map_value(decoded, :context)
        end

      true ->
        {:ok, source}
    end
  end

  defp data_source(source, _base_dir, _opts), do: {:error, {:invalid_data_source, source}}

  defp input_text("-", opts) do
    device = Keyword.get(opts, :input_device, :stdio)

    case IO.read(device, :eof) do
      text when is_binary(text) -> validate_text(text, "-")
      {:error, reason} -> {:error, {:input_read_failed, reason}}
    end
    |> case do
      {:ok, text} -> {:ok, text, "-"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp input_text(path, opts) do
    path = Path.expand(path)

    with {:ok, text} <- read_text(path, opts) do
      {:ok, text, path}
    end
  end

  defp decode_file(path, opts) do
    with {:ok, contents} <- read_text(path, opts),
         {:ok, decoded} <- decode(contents, path),
         true <- is_map(decoded) or {:error, {:document_must_be_map, path}} do
      {:ok, decoded, contents}
    end
  end

  defp decode(contents, path) do
    case String.downcase(Path.extname(path)) do
      ".json" -> Jason.decode(contents)
      _extension -> YamlElixir.read_from_string(contents, merge_anchors: false)
    end
  rescue
    exception -> {:error, {:decode_failed, path, Exception.message(exception)}}
  end

  defp read_text(path, opts) do
    max_bytes = Keyword.get(opts, :max_file_bytes, @default_max_bytes)

    with {:ok, stat} <- File.stat(path),
         :ok <- within_limit(path, stat.size, max_bytes),
         {:ok, contents} <- File.read(path),
         {:ok, contents} <- validate_text(contents, path) do
      {:ok, contents}
    else
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  defp validate_text(text, path) do
    if String.valid?(text), do: {:ok, text}, else: {:error, {:invalid_utf8, path}}
  end

  defp within_limit(_path, size, max_bytes) when size <= max_bytes, do: :ok
  defp within_limit(path, size, max_bytes), do: {:error, {:file_too_large, path, size, max_bytes}}

  defp version_one(document, path) do
    case Map.get(document, "version", 1) do
      1 -> :ok
      version -> {:error, {:unsupported_document_version, path, version, 1}}
    end
  end

  defp required_map(map, key, path) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      value -> {:error, {:invalid_required_map, path, key, value}}
    end
  end

  defp required_id(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_required_id, path, key, value}}
    end
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_required_string, key, value}}
    end
  end

  defp optional_id(nil, default), do: {:ok, default}
  defp optional_id(value, _default) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_id(value, _default), do: {:error, {:invalid_id, value}}

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value), do: {:ok, value}
  defp optional_string(value), do: {:error, {:invalid_string, value}}

  defp optional_profile(nil), do: {:ok, nil}
  defp optional_profile(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_profile(value), do: {:error, {:invalid_execution_profile, value}}

  defp optional_section(map, key) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> {:ok, value}
      value -> {:error, {:invalid_optional_map, key, value}}
    end
  end

  defp reject_execution_controls(map) when is_map(map) do
    keys = map |> Map.keys() |> Enum.map(&to_string/1)

    case keys -- (keys -- @forbidden_execution_keys) do
      [] -> :ok
      forbidden -> {:error, {:forbidden_execution_profile_keys, Enum.sort(forbidden)}}
    end
  end

  defp optional_map(nil), do: {:ok, nil}
  defp optional_map(value) when is_map(value), do: {:ok, value}
  defp optional_map(value), do: {:error, {:invalid_map, value}}

  defp optional_output(nil, _base_dir), do: {:ok, nil}

  defp optional_output(value, base_dir) when is_binary(value) and value != "",
    do: {:ok, resolve_path(base_dir, value)}

  defp optional_output(value, _base_dir), do: {:error, {:invalid_output_directory, value}}

  defp string_or_list(nil, _field), do: {:ok, nil}
  defp string_or_list(value, _field) when is_binary(value), do: {:ok, value}

  defp string_or_list(values, _field)
       when is_list(values) and values != [] do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, {:invalid_string_list, values}}
  end

  defp string_or_list(value, field), do: {:error, {:invalid_assertion, field, value}}

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value, field), do: {:error, {:invalid_positive_integer, field, value}}

  defp map_value(value, _field) when is_map(value), do: {:ok, value}
  defp map_value(value, field), do: {:error, {:invalid_map_value, field, value}}

  defp matrix_value(suite, key, default) do
    suite |> Map.get("matrix", %{}) |> Map.get(key, Map.get(suite, key, default))
  end

  defp run_value(suite, key, default) do
    suite |> Map.get("run", %{}) |> Map.get(key, default)
  end

  defp unique_values(items, field, kind) do
    duplicate =
      items
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.frequencies()
      |> Enum.find_value(fn {value, count} -> if count > 1, do: value end)

    if duplicate, do: {:error, {:duplicate_id, kind, duplicate}}, else: :ok
  end

  defp resolve_path(base_dir, path), do: Path.expand(path, base_dir)

  defp key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "item"
      key -> key
    end
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
