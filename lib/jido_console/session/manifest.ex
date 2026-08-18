defmodule Jido.Console.Session.Manifest do
  @moduledoc "Immutable durable turn manifests and exact continuation compatibility checks."

  alias Jido.Console.Credential.Profile
  alias Jido.Console.Session.AuditProjection
  alias Jido.Console.Session.Durable.{CanonicalJSON, Record, Value}
  alias Jido.Console.Storage

  @scope_prefix "turn-manifest:"
  @identity_fields ~w(
    provider_id model_id variant_id settings_digest agent_spec_digest prompt_digest
    tool_schema_digest skill_schema_digest extension_descriptor_digest protocol_digest
    coding_profile_id execution_environment_id
  )

  @doc "Returns a portable digest for one accepted manifest input value."
  @spec identity(term()) :: {:ok, String.t()} | {:error, term()}
  def identity(value) do
    with :ok <- Value.validate(value),
         {:ok, bytes} <- CanonicalJSON.encode(%{"value" => value}) do
      {:ok, Jido.Console.Digest.portable(bytes)}
    end
  end

  @doc "Persists one immutable turn and invocation manifest."
  @spec create(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(session_id, manifest, opts \\ [])

  def create(session_id, manifest, opts) when is_binary(session_id) and is_map(manifest) do
    with true <- valid_id?(session_id),
         true <- valid_id?(manifest["request_id"]),
         :ok <- AuditProjection.scan(manifest, Keyword.get(opts, :forbidden_values, [])),
         scope_id = scope_id(session_id, manifest["request_id"]),
         record =
           Record.new("turn_manifest", manifest,
             record_id: scope_id,
             scope_id: scope_id,
             generation: Keyword.get(opts, :generation, 0),
             sequence: 0,
             prior_record_digest: "genesis"
           ),
         {:ok, encoded} <- Record.encode(record),
         {:ok, operation_id} <- operation_id(opts),
         {:ok, records} <- storage(opts).range(scope_id, read_opts(opts)) do
      create_or_return(records, record, encoded, operation_id, session_id, opts)
    else
      false -> {:error, :invalid_turn_manifest_scope}
      {:error, _reason} = error -> error
    end
  end

  def create(_session_id, _manifest, _opts), do: {:error, :invalid_turn_manifest}

  @doc "Loads the exact immutable manifest without resolving a credential source."
  @spec load(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(session_id, request_id, opts \\ []) do
    with true <- valid_id?(session_id) and valid_id?(request_id),
         {:ok, records} <- storage(opts).range(scope_id(session_id, request_id), read_opts(opts)) do
      case records do
        [encoded] -> {:ok, encoded.record["payload"]}
        [] -> {:error, {:turn_manifest_not_found, session_id, request_id}}
        _records -> {:error, {:turn_manifest_cardinality, session_id, request_id}}
      end
    else
      false -> {:error, :invalid_turn_manifest_scope}
      {:error, _reason} = error -> error
    end
  end

  @doc "Checks exact registry, workspace, environment, and credential identities before continuation."
  @spec compatibility(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def compatibility(session_id, request_id, current, opts \\ [])

  def compatibility(session_id, request_id, current, opts) when is_map(current) do
    with {:ok, manifest} <- load(session_id, request_id, opts),
         :ok <- compare_identities(manifest, current),
         :ok <- compare_workspace(manifest, current),
         :ok <- compare_credential(manifest, opts) do
      {:ok, %{status: :compatible, manifest: manifest}}
    end
  end

  def compatibility(_session_id, _request_id, _current, _opts),
    do: {:error, :invalid_turn_manifest_compatibility_input}

  defp create_or_return([], record, encoded, operation_id, _session_id, opts),
    do: append_or_return(record, encoded, operation_id, opts)

  defp create_or_return([existing], record, encoded, operation_id, session_id, opts) do
    record_id = record["record_id"]
    encoded_digest = encoded.digest
    existing_digest = existing.digest

    case storage(opts).receipt(operation_id, opts) do
      {:ok, %{target_id: target, result_digest: digest}}
      when target == record_id and digest == encoded_digest and digest == existing_digest ->
        {:ok, %{manifest: record["payload"], digest: digest, duplicate: true}}

      {:ok, _receipt} ->
        {:error, {:turn_manifest_operation_conflict, operation_id}}

      {:error, {:operation_not_found, ^operation_id}} ->
        {:error, {:turn_manifest_exists, session_id, record["payload"]["request_id"]}}

      {:error, _reason} = error ->
        error
    end
  end

  defp create_or_return(_records, record, _encoded, _operation_id, session_id, _opts),
    do: {:error, {:turn_manifest_cardinality, session_id, record["payload"]["request_id"]}}

  defp append_or_return(record, encoded, operation_id, opts) do
    case storage(opts).receipt(operation_id, opts) do
      {:ok, %{target_id: target, result_digest: digest}} ->
        if target == record["record_id"] and digest == encoded.digest do
          {:ok, %{manifest: record["payload"], digest: digest, duplicate: true}}
        else
          {:error, {:turn_manifest_operation_conflict, operation_id}}
        end

      {:error, {:operation_not_found, ^operation_id}} ->
        with {:ok, result} <- storage(opts).append(record, Keyword.put(opts, :operation_id, operation_id)) do
          {:ok, %{manifest: record["payload"], digest: result.digest, duplicate: false}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp compare_identities(manifest, current) do
    Enum.reduce_while(@identity_fields, :ok, fn field, :ok ->
      expected = manifest[field]

      case fetch(current, field) do
        :error -> {:halt, {:error, {:turn_manifest_identity_missing, field, expected}}}
        {:ok, ^expected} -> {:cont, :ok}
        {:ok, actual} -> {:halt, {:error, {:turn_manifest_identity_incompatible, field, expected, actual}}}
      end
    end)
  end

  defp compare_workspace(manifest, current) do
    with {:ok, workspace_id} <- fetch(current, "workspace_id"),
         {:ok, workspace_digest} <- fetch(current, "workspace_digest") do
      if workspace_id == manifest["workspace_id"] and workspace_digest == manifest["workspace_digest"] do
        :ok
      else
        {:error,
         {:workspace_drift,
          %{
            workspace_id: manifest["workspace_id"],
            accepted_digest: manifest["workspace_digest"],
            current_workspace_id: workspace_id,
            current_digest: workspace_digest
          }}}
      end
    else
      :error -> {:error, :workspace_identity_missing}
    end
  end

  defp compare_credential(%{"credential_profile_id" => nil}, _opts), do: :ok

  defp compare_credential(manifest, opts) do
    selection = %{
      profile_id: manifest["credential_profile_id"],
      profile_version: manifest["credential_profile_version"],
      reference_id: manifest["credential_reference_id"],
      source_identity: manifest["credential_source_identity"]
    }

    case Profile.compatibility(selection, opts) do
      {:ok, _compatible} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp fetch(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Enum.find(map, fn {key, _value} -> is_atom(key) and Atom.to_string(key) == field end) do
          {_key, value} -> {:ok, value}
          nil -> :error
        end
    end
  end

  defp read_opts(opts), do: Keyword.merge(opts, limit: 2, max_bytes: 512 * 1_024)

  defp operation_id(opts) do
    case Keyword.get(opts, :operation_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :operation_id_required}
    end
  end

  defp scope_id(session_id, request_id), do: "#{@scope_prefix}#{session_id}:#{request_id}"
  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value)
  defp storage(opts), do: Keyword.get(opts, :storage, Storage)
end
