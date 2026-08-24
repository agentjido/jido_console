defmodule Jido.Console.AgentSource.Admission do
  @moduledoc false

  @max_bytes 1_000_000
  @max_depth 64
  @max_nodes 20_000

  @document_fields ~w(version agent runtime_defaults metadata)
  @agent_fields ~w(id instructions model generation execution_profile memory runtime_defaults metadata)
  @flat_fields ~w(version id instructions model generation execution_profile memory runtime_defaults metadata)
  @runtime_default_fields ~w(max_model_turns timeout_ms)
  @memory_fields ~w(enabled capture inject max_entries)

  @forbidden_fields ~w(
    tools tool operations operation extensions extension controls control
    operation_controls operation_control
    context context_schema result result_schema schema schemas registries registry
    context_registry context_schema_registry result_registry result_schema_registry
    schema_registry operation_registry extension_registry control_registry tool_registry
    actions action action_registry ash_resources ash_resource_registry catalogs catalog_registry
    adapters adapter execution_environment backend command image mount mounts network
    coding coding_pack coding_packs coding_profile
    execution_policy execution_policy_id security_profile profile_resolver policy_resolver
    registration registrations consent workspace workspace_root workspace_roots
    shared_memory shared_memory_route shared_memory_routes memory_route memory_routes
  )

  @type format :: :json | :yaml

  @doc false
  @spec admit(binary(), format(), keyword()) ::
          {:ok, Jidoka.Agent.Spec.t()} | {:error, term()}
  def admit(bytes, format, opts \\ [])

  def admit(bytes, format, opts)
      when is_binary(bytes) and format in [:json, :yaml] and is_list(opts) do
    with {:ok, decoded} <- syntax_preflight(bytes, format),
         :ok <- admit_document(decoded),
         :ok <- before_import(bytes, format, opts),
         {:ok, %Jidoka.Agent.Spec{} = spec} <- import_spec(bytes, format) do
      {:ok, spec}
    end
  end

  def admit(_bytes, _format, _opts), do: {:error, :invalid_agent_source_admission}

  defp syntax_preflight(bytes, :json) do
    case Jason.decode(bytes, objects: :ordered_objects, strings: :copy) do
      {:ok, value} -> json_value(value)
      {:error, _reason} -> {:error, {:invalid_syntax, :json}}
    end
  end

  defp syntax_preflight(bytes, :yaml) do
    with :ok <- yaml_tokens(bytes),
         {:ok, pairs} <- yaml_pairs(bytes),
         :ok <- validate_yaml_pairs(pairs) do
      yaml_decoded(bytes)
    end
  end

  defp json_value(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if MapSet.size(MapSet.new(keys)) == length(keys) do
      pairs
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, map} ->
        case json_value(value) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(map, key, decoded)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, {:duplicate_key, :json}}
    end
  end

  defp json_value(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, decoded} ->
      case json_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end)
  end

  defp json_value(value), do: {:ok, value}

  defp yaml_tokens(bytes) do
    marker = {__MODULE__, make_ref()}
    Process.put(marker, [])

    token_fun = fn token ->
      Process.put(marker, [token | Process.get(marker, [])])
      :ok
    end

    try do
      _parser = :yamerl_parser.string(bytes, token_fun: token_fun)
      marker |> Process.delete() |> Enum.reverse() |> validate_yaml_tokens()
    rescue
      _exception ->
        Process.delete(marker)
        {:error, {:invalid_syntax, :yaml}}
    catch
      _kind, _reason ->
        Process.delete(marker)
        {:error, {:invalid_syntax, :yaml}}
    end
  end

  defp validate_yaml_tokens(tokens) do
    forbidden =
      Enum.find_value(tokens, fn token ->
        yaml_forbidden_token(token)
      end)

    document_count = Enum.count(tokens, &(elem(&1, 0) == :yamerl_doc_start))

    cond do
      forbidden -> {:error, {:forbidden_yaml_syntax, forbidden}}
      document_count > 1 -> {:error, {:forbidden_yaml_syntax, :multiple_documents}}
      true -> :ok
    end
  end

  defp yaml_forbidden_token({:yamerl_anchor, _line, _column, _name}), do: :anchor
  defp yaml_forbidden_token({:yamerl_alias, _line, _column, _name}), do: :alias
  defp yaml_forbidden_token({:yamerl_tag, _line, _column, _uri}), do: :tag
  defp yaml_forbidden_token({:yamerl_tag_directive, _line, _column, _handle, _prefix}), do: :tag

  defp yaml_forbidden_token({:yamerl_collection_start, _line, _column, tag, _style, _kind}),
    do: explicit_yaml_tag(tag)

  defp yaml_forbidden_token({:yamerl_scalar, _line, _column, tag, _style, _substyle, _text}),
    do: explicit_yaml_tag(tag)

  defp yaml_forbidden_token(_token), do: nil

  defp explicit_yaml_tag({:yamerl_tag, _line, _column, {:non_specific, _kind}}), do: nil
  defp explicit_yaml_tag({:yamerl_tag, _line, _column, _uri}), do: :tag
  defp explicit_yaml_tag(_tag), do: nil

  defp yaml_pairs(bytes) do
    case YamlElixir.read_from_string(bytes, maps_as_keywords: true, merge_anchors: false) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:invalid_syntax, :yaml}}
    end
  end

  defp yaml_decoded(bytes) do
    case YamlElixir.read_from_string(bytes, merge_anchors: false) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:invalid_syntax, :yaml}}
    end
  end

  defp validate_yaml_pairs(values) when is_list(values) do
    if Enum.all?(values, &(is_tuple(&1) and tuple_size(&1) == 2)) do
      validate_yaml_mapping(values)
    else
      validate_yaml_sequence(values)
    end
  end

  defp validate_yaml_pairs(_value), do: :ok

  defp validate_yaml_mapping(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))

    cond do
      Enum.any?(keys, &merge_key?/1) ->
        {:error, {:forbidden_yaml_syntax, :merge_key}}

      MapSet.size(MapSet.new(keys)) != length(keys) ->
        {:error, {:duplicate_key, :yaml}}

      true ->
        Enum.reduce_while(pairs, :ok, fn {key, value}, :ok ->
          with :ok <- validate_yaml_pairs(key),
               :ok <- validate_yaml_pairs(value) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_yaml_sequence(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate_yaml_pairs(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp merge_key?(key) when is_binary(key), do: key == "<<" or String.starts_with?(key, "<<")
  defp merge_key?(_key), do: false

  defp admit_document(%{} = document) do
    with :ok <- reject_forbidden_nested(document) do
      admit_document_shape(document)
    end
  end

  defp admit_document(_document), do: {:error, {:forbidden_agent_field, "document"}}

  defp admit_document_shape(%{"agent" => agent} = document) do
    with :ok <- allow_only(document, @document_fields) do
      admit_nested_agent(agent, document["runtime_defaults"])
    end
  end

  defp admit_document_shape(document) do
    with :ok <- allow_only(document, @flat_fields),
         :ok <- admit_memory(document["memory"]) do
      admit_runtime_defaults(document["runtime_defaults"])
    end
  end

  defp admit_nested_agent(%{} = agent, document_defaults) do
    with :ok <- allow_only(agent, @agent_fields),
         :ok <- admit_memory(agent["memory"]),
         :ok <- admit_runtime_defaults(agent["runtime_defaults"]) do
      admit_runtime_defaults(document_defaults)
    end
  end

  defp admit_nested_agent(_agent, _document_defaults),
    do: {:error, {:forbidden_agent_field, "agent"}}

  defp reject_forbidden_nested(%{} = map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      key = to_string(key)

      if key in @forbidden_fields,
        do: {:halt, {:error, {:forbidden_agent_field, key}}},
        else: continue_nested(value)
    end)
  end

  defp reject_forbidden_nested(values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok -> continue_nested(value) end)
  end

  defp reject_forbidden_nested(_value), do: :ok

  defp continue_nested(value) do
    case reject_forbidden_nested(value) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp allow_only(map, allowed) do
    case map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.find(&(&1 not in allowed)) do
      nil -> :ok
      field -> {:error, {:forbidden_agent_field, field}}
    end
  end

  defp admit_runtime_defaults(nil), do: :ok
  defp admit_runtime_defaults(%{} = defaults), do: allow_only(defaults, @runtime_default_fields)
  defp admit_runtime_defaults(_defaults), do: {:error, {:forbidden_agent_field, "runtime_defaults"}}

  defp admit_memory(nil), do: :ok
  defp admit_memory(memory) when is_boolean(memory), do: :ok
  defp admit_memory(%{} = memory), do: allow_only(memory, @memory_fields)
  defp admit_memory(_memory), do: {:error, {:forbidden_agent_field, "memory"}}

  defp before_import(bytes, format, opts) do
    case Keyword.get(opts, :before_import) do
      nil ->
        :ok

      callback when is_function(callback, 2) ->
        _result = callback.(bytes, format)
        :ok

      _callback ->
        {:error, :invalid_agent_source_admission_callback}
    end
  end

  defp import_spec(bytes, format) do
    case Jidoka.import(bytes,
           format: format,
           max_import_bytes: @max_bytes,
           max_import_depth: @max_depth,
           max_import_nodes: @max_nodes,
           yaml_merge_anchors: false,
           discover_mcp?: false
         ) do
      {:ok, %Jidoka.Agent.Spec{} = spec} -> {:ok, spec}
      {:error, error} -> {:error, import_error(error)}
    end
  end

  defp import_error(%{details: %{reason: {:import_too_deep, _actual, @max_depth}}}),
    do: {:import_limit, :depth}

  defp import_error(%{details: %{reason: {:import_too_large, :nodes, _actual, @max_nodes}}}),
    do: {:import_limit, :nodes}

  defp import_error(%{details: %{reason: {:import_too_large, :bytes, _actual, @max_bytes}}}),
    do: {:import_limit, :bytes}

  defp import_error(_error), do: :invalid_agent_document
end
