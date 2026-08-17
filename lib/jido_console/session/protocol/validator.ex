defmodule Jido.Console.Session.Protocol.Validator do
  @moduledoc """
  Validates protocol envelopes against the generated catalog.

  A declared payload field is valid only for its exact family and type.
  Undeclared extension fields are retained only within declared bounds and
  cannot grant authority, permission, or control.
  """

  alias Jido.Console.Session.Protocol.Generated

  @type result :: {:ok, map()} | {:error, term()}

  @doc "Validates one protocol envelope."
  @spec validate(map(), keyword()) :: result()
  def validate(value, opts \\ [])

  def validate(value, opts) when is_map(value) do
    catalog = Keyword.get_lazy(opts, :catalog, &Generated.catalog/0)

    with :ok <- require_envelope(value),
         :ok <- compatible_version(value, catalog),
         {:ok, contract} <- type_contract(value, catalog),
         :ok <- json_compatible(value),
         :ok <- reject_client_local_payload(value, contract, catalog),
         :ok <- reject_sensitive_payload(value["payload"] || %{}, catalog),
         {:ok, payload} <- validate_payload(value, contract, catalog) do
      {:ok, Map.put(value, "payload", payload)}
    end
  end

  def validate(_value, _opts), do: {:error, :invalid_protocol_shape}

  @doc "Validates JSON text as a protocol envelope."
  @spec validate_json(String.t(), keyword()) :: result()
  def validate_json(json, opts \\ []) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> validate(value, opts)
      {:error, reason} -> {:error, {:invalid_protocol_json, reason}}
    end
  end

  @doc "Validates a final provider or tool value and blocks a materialized credential value."
  @spec validate_final_boundary(map(), [String.t()], keyword()) :: result()
  def validate_final_boundary(value, materialized_values, opts \\ [])

  def validate_final_boundary(value, materialized_values, opts)
      when is_map(value) and is_list(materialized_values) do
    with {:ok, validated} <- validate(value, opts),
         :ok <- reject_materialized_values(validated, materialized_values) do
      {:ok, validated}
    end
  end

  def validate_final_boundary(_value, _materialized_values, _opts), do: {:error, :invalid_protocol_shape}

  defp require_envelope(value) do
    required = ~w(protocol version family type id)

    cond do
      Enum.any?(required, &(not is_binary(value[&1]) or value[&1] == "")) ->
        {:error, :invalid_protocol_envelope}

      value["protocol"] != "jido.session" ->
        {:error, {:invalid_protocol_name, value["protocol"]}}

      true ->
        :ok
    end
  end

  defp compatible_version(%{"version" => version}, catalog) do
    if version == catalog["version"] do
      :ok
    else
      {:error, {:incompatible_protocol_version, version}}
    end
  end

  defp type_contract(%{"family" => family, "type" => type}, catalog) do
    case get_in(catalog, ["families", family, "types", type]) do
      contract when is_map(contract) -> {:ok, contract}
      _other -> {:error, {:unknown_protocol_type, family, type}}
    end
  end

  defp reject_client_local_payload(%{"payload" => payload}, contract, catalog)
       when is_map(payload) do
    local_fields = MapSet.new(catalog["client_local_fields"] || [])

    cond do
      contract["locality"] != "shared" ->
        :ok

      Enum.any?(Map.keys(payload), &MapSet.member?(local_fields, &1)) ->
        {:error, :client_local_forbidden}

      true ->
        :ok
    end
  end

  defp reject_client_local_payload(%{"payload" => payload}, _contract, _catalog) when not is_map(payload) do
    {:error, :invalid_protocol_payload}
  end

  defp reject_client_local_payload(_value, _contract, _catalog), do: :ok

  defp validate_payload(%{"family" => family, "type" => type} = value, contract, catalog) do
    payload = value["payload"] || %{}

    with :ok <- require_payload_fields(payload, family, type, contract),
         :ok <- reject_sibling_fields(payload, family, type, contract, catalog),
         :ok <- validate_field_values(payload, family, type, contract) do
      bound_payload(payload, contract, catalog)
    end
  end

  defp require_payload_fields(payload, family, type, contract) when is_map(payload) do
    missing = List.wrap(contract["required_fields"]) -- Map.keys(payload)

    if missing == [] do
      :ok
    else
      {:error, {:missing_protocol_fields, family, type, missing}}
    end
  end

  defp require_payload_fields(_payload, _family, _type, _contract), do: {:error, :invalid_protocol_payload}

  defp reject_sibling_fields(payload, family, type, contract, catalog) when is_map(payload) do
    known = MapSet.new(contract["known_fields"] || [])

    unexpected =
      payload
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.filter(&MapSet.member?(family_field_set(catalog, family), &1))
      |> Enum.sort()

    if unexpected == [] do
      :ok
    else
      {:error, {:unexpected_protocol_fields, family, type, unexpected}}
    end
  end

  defp validate_field_values(payload, family, type, contract) do
    contract
    |> Map.get("field_values", %{})
    |> Enum.reduce_while(:ok, fn {field, allowed}, :ok ->
      if Map.has_key?(payload, field) and payload[field] not in allowed do
        {:halt, {:error, {:invalid_protocol_field_value, family, type, field}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp bound_payload(payload, contract, catalog) when is_map(payload) do
    bounds = catalog["bounds"]
    authority = catalog["authority"]
    unknown_limit = bounds["max_unknown_bytes"]
    unknown_keys = bounds["max_unknown_keys"]
    known = MapSet.new(contract["known_fields"] || [])

    with :ok <- bound_value(payload, bounds),
         :ok <- reject_unknown_authority(payload, known, authority) do
      unknown =
        payload
        |> Map.drop(MapSet.to_list(known))
        |> Map.drop(authority_fields(authority))

      cond do
        map_size(unknown) > unknown_keys ->
          {:error, :unknown_data_overflow}

        encoded_size(unknown) > unknown_limit ->
          {:error, :unknown_data_overflow}

        is_integer(contract["max_encoded_bytes"]) and
            encoded_size(payload) > contract["max_encoded_bytes"] ->
          {:error, :oversized_protocol_payload}

        true ->
          {:ok, payload}
      end
    end
  end

  defp bound_value(value, bounds) when is_binary(value) do
    limit = bounds["max_text_bytes"]

    if byte_size(value) <= limit do
      :ok
    else
      {:error, {:oversized_protocol_value, byte_size(value), limit}}
    end
  end

  defp bound_value(value, bounds) when is_list(value) do
    if length(value) <= bounds["max_list_items"] do
      Enum.reduce_while(value, :ok, fn item, :ok ->
        case bound_value(item, bounds) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :oversized_protocol_list}
    end
  end

  defp bound_value(value, bounds) when is_map(value) do
    if map_size(value) <= bounds["max_map_keys"] do
      Enum.reduce_while(value, :ok, fn {_key, item}, :ok ->
        case bound_value(item, bounds) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :oversized_protocol_map}
    end
  end

  defp bound_value(_value, _bounds), do: :ok

  defp json_compatible(value) when is_binary(value) or is_integer(value) or is_float(value), do: :ok
  defp json_compatible(value) when is_boolean(value) or is_nil(value), do: :ok

  defp json_compatible(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case json_compatible(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp json_compatible(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn
      {key, item}, :ok when is_binary(key) ->
        case json_compatible(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {_key, _item}, :ok ->
        {:halt, {:error, :non_string_protocol_key}}
    end)
  end

  defp json_compatible(value) when is_pid(value), do: {:error, {:forbidden_runtime_value, :pid}}
  defp json_compatible(value) when is_reference(value), do: {:error, {:forbidden_runtime_value, :reference}}
  defp json_compatible(value) when is_port(value), do: {:error, {:forbidden_runtime_value, :port}}
  defp json_compatible(value) when is_function(value), do: {:error, {:forbidden_runtime_value, :function}}
  defp json_compatible(value) when is_struct(value), do: {:error, {:forbidden_runtime_value, :struct}}
  defp json_compatible(_value), do: {:error, :non_json_protocol_value}

  defp reject_sensitive_payload(payload, catalog) do
    policy = catalog["sensitive_values"] || %{}

    case sensitive_violation(payload, [], nil, policy) do
      nil ->
        :ok

      %{field: field, reason: reason, surface: surface} ->
        {:error,
         {:sensitive_value_rejected, surface,
          %{"field" => field, "reason" => Atom.to_string(reason), "redacted" => true}}}
    end
  end

  defp sensitive_violation(value, path, _parent, policy) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      normalized = normalize_field(key)

      if forbidden_field?(normalized, policy) do
        %{field: normalized, reason: :forbidden_field, surface: surface(path, key)}
      else
        sensitive_violation(item, path ++ [key], key, policy)
      end
    end)
  end

  defp sensitive_violation(value, path, parent, policy) when is_list(value) do
    structural? = normalize_field(parent) in List.wrap(policy["structural_string_fields"])

    Enum.find_value(value, fn item ->
      if structural? and is_binary(item) and forbidden_shell_argument?(item, policy) do
        %{field: normalize_field(parent), reason: :credential_argument, surface: surface(path, parent)}
      else
        sensitive_violation(item, path, parent, policy)
      end
    end)
  end

  defp sensitive_violation(value, path, parent, policy) when is_binary(value) do
    field = normalize_field(parent)
    structural? = field in List.wrap(policy["structural_string_fields"])
    uri? = field in List.wrap(policy["uri_fields"])

    cond do
      uri? and URI.parse(value).userinfo not in [nil, ""] ->
        %{field: field, reason: :uri_userinfo, surface: surface(path, parent)}

      structural? and forbidden_shell_argument?(value, policy) ->
        %{field: field, reason: :credential_argument, surface: surface(path, parent)}

      structural? and credential_interpolation?(value) ->
        %{field: field, reason: :credential_interpolation, surface: surface(path, parent)}

      true ->
        nil
    end
  end

  defp sensitive_violation(_value, _path, _parent, _policy), do: nil

  defp forbidden_field?(field, policy) do
    allowed = List.wrap(policy["allowed_reference_fields"])
    forbidden = List.wrap(policy["forbidden_field_names"])

    fragments =
      ~w(api_key access_token auth_token bearer_token credential_value password private_key refresh_token secret_value session_cookie)

    field not in allowed and
      (field in forbidden or Enum.any?(fragments, &String.contains?(field, &1)))
  end

  defp forbidden_shell_argument?(value, policy) do
    value = String.downcase(value)

    Enum.any?(List.wrap(policy["forbidden_shell_flags"]), fn flag ->
      value == flag or String.starts_with?(value, flag <> "=") or String.contains?(value, " " <> flag <> " ")
    end)
  end

  defp credential_interpolation?(value) do
    Regex.match?(~r/\$\{[^}]*(api[_-]?key|password|secret|token|credential)[^}]*\}/i, value)
  end

  defp surface(path, field) do
    path
    |> List.first()
    |> case do
      nil -> normalize_field(field)
      first -> normalize_field(first)
    end
  end

  defp normalize_field(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_field(_value), do: "unknown"

  defp reject_materialized_values(value, materialized_values) do
    secrets = Enum.filter(materialized_values, &(is_binary(&1) and &1 != ""))

    case materialized_value_path(value, [], secrets) do
      nil ->
        :ok

      path ->
        {:error,
         {:sensitive_result_blocked, :final_boundary,
          %{"path" => Enum.join(path, "."), "reason" => "materialized_value", "redacted" => true}}}
    end
  end

  defp materialized_value_path(value, path, secrets) when is_binary(value) do
    if Enum.any?(secrets, &String.contains?(value, &1)), do: path, else: nil
  end

  defp materialized_value_path(value, path, secrets) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {item, index} ->
      materialized_value_path(item, path ++ [Integer.to_string(index)], secrets)
    end)
  end

  defp materialized_value_path(value, path, secrets) when is_map(value) do
    Enum.find_value(value, fn {key, item} -> materialized_value_path(item, path ++ [to_string(key)], secrets) end)
  end

  defp materialized_value_path(_value, _path, _secrets), do: nil

  defp reject_unknown_authority(payload, known, authority) do
    forbidden = MapSet.new(authority_fields(authority))

    leaked =
      payload
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.filter(&MapSet.member?(forbidden, &1))

    if leaked == [], do: :ok, else: {:error, {:unknown_authority_field, leaked}}
  end

  defp family_field_set(catalog, family) do
    catalog
    |> get_in(["families", family, "types"])
    |> List.wrap()
    |> Enum.flat_map(fn
      types when is_map(types) ->
        Enum.flat_map(types, fn {_name, contract} -> List.wrap(contract["known_fields"]) end)

      _other ->
        []
    end)
    |> MapSet.new()
  end

  defp authority_fields(%{"authority_fields" => fields}) when is_list(fields), do: fields
  defp authority_fields(_authority), do: []

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _reason} -> :infinity
    end
  end
end
