defmodule Jido.Console.Session.Durable.Value do
  @moduledoc "Pre-encode rejection for runtime, renderer, client, and credential-bearing values."

  alias Jido.Console.Session.Protocol

  @raw_client_fields ~w(client provider_client raw_client raw_provider_client request_handle)
  @credential_query_fields ~w(api_key apikey authorization credential password private_key secret token)

  @doc "Validates a value before durable encoding without resolving an external credential source."
  @spec validate(term(), keyword()) :: :ok | {:error, term()}
  def validate(value, opts \\ []) do
    {:ok, schema} = Protocol.schema()
    {:ok, policy} = Protocol.sensitive_values(schema)
    local_fields = MapSet.new(Protocol.client_local_fields(schema))

    walk(value, [], nil, policy, local_fields, opts)
  end

  defp walk(value, _path, _parent, _policy, _local_fields, _opts)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: :ok

  defp walk(value, path, parent, policy, _local_fields, _opts) when is_binary(value) do
    field = normalize(parent)

    cond do
      field in List.wrap(policy["uri_fields"]) and credential_uri?(value) ->
        reject(path, :credential_uri)

      field in List.wrap(policy["structural_string_fields"]) and shell_credential?(value, policy) ->
        reject(path, :credential_argument)

      field in List.wrap(policy["structural_string_fields"]) and credential_interpolation?(value) ->
        reject(path, :credential_interpolation)

      true ->
        :ok
    end
  end

  defp walk(value, path, parent, policy, local_fields, opts) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case walk(item, path ++ [Integer.to_string(index)], parent, policy, local_fields, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp walk(%module{} = value, path, parent, policy, local_fields, opts) do
    allow_struct = Keyword.get(opts, :allow_struct, fn _module -> false end)

    if allow_struct.(module) do
      walk(Map.from_struct(value), path, parent, policy, local_fields, opts)
    else
      reject(path, {:forbidden_runtime_value, :struct})
    end
  end

  defp walk(value, path, _parent, policy, local_fields, opts) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      field = normalize(key)
      item_path = path ++ [field]

      cond do
        not (is_binary(key) or is_atom(key)) ->
          {:halt, reject(item_path, :invalid_map_key)}

        forbidden_field?(field, policy) ->
          {:halt, reject(item_path, :credential_field)}

        MapSet.member?(local_fields, field) ->
          {:halt, reject(item_path, :client_local_state)}

        field in @raw_client_fields ->
          {:halt, reject(item_path, :raw_provider_client)}

        true ->
          case walk(item, item_path, field, policy, local_fields, opts) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp walk(value, path, _parent, _policy, _local_fields, _opts) when is_pid(value),
    do: reject(path, {:forbidden_runtime_value, :pid})

  defp walk(value, path, _parent, _policy, _local_fields, _opts) when is_reference(value),
    do: reject(path, {:forbidden_runtime_value, :reference})

  defp walk(value, path, _parent, _policy, _local_fields, _opts) when is_port(value),
    do: reject(path, {:forbidden_runtime_value, :port})

  defp walk(value, path, _parent, _policy, _local_fields, _opts) when is_function(value),
    do: reject(path, {:forbidden_runtime_value, :function})

  defp walk(value, _path, _parent, _policy, _local_fields, _opts) when is_atom(value), do: :ok
  defp walk(_value, path, _parent, _policy, _local_fields, _opts), do: reject(path, :nonportable_value)

  defp forbidden_field?(field, policy) do
    allowed = List.wrap(policy["allowed_reference_fields"])
    forbidden = List.wrap(policy["forbidden_field_names"])

    fragments =
      ~w(api_key access_token auth_token bearer_token credential_value password private_key refresh_token secret_value session_cookie)

    field not in allowed and
      (field in forbidden or Enum.any?(fragments, &String.contains?(field, &1)))
  end

  defp credential_uri?(value) do
    uri = URI.parse(value)
    uri.userinfo not in [nil, ""] or credential_query?(uri.query)
  rescue
    _exception -> false
  end

  defp credential_query?(nil), do: false

  defp credential_query?(query) do
    query
    |> URI.query_decoder()
    |> Enum.any?(fn {key, _value} -> normalize(key) in @credential_query_fields end)
  rescue
    _exception -> false
  end

  defp shell_credential?(value, policy) do
    downcase = String.downcase(value)

    Enum.any?(List.wrap(policy["forbidden_shell_flags"]), fn flag ->
      downcase == flag or String.starts_with?(downcase, flag <> "=") or
        String.contains?(downcase, " " <> flag <> " ")
    end)
  end

  defp credential_interpolation?(value) do
    Regex.match?(~r/\$\{[^}]*(api[_-]?key|password|secret|token|credential)[^}]*\}/i, value)
  end

  defp reject(path, reason) do
    {:error,
     {:sensitive_value_rejected, %{"path" => Enum.join(path, "."), "reason" => inspect(reason), "redacted" => true}}}
  end

  defp normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()

  defp normalize(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize(_value), do: "unknown"
end
