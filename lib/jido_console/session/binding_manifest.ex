defmodule Jido.Console.Session.BindingManifest do
  @moduledoc "Versioned durable evidence for one Console session binding."

  alias Jido.Console.Digest
  alias Jido.Console.ExecutionPolicy.Record
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jido.Console.Session.Binding
  alias Jidoka.Session.Data

  @metadata_key "jido_console_binding"
  @version 1
  @keys ~w(
    version lock_state draft_generation lock_operation_id first_prompt_command_digest
    source base_spec_digest bound_spec_digest runtime_definition_fingerprint
    coding_pack model execution_policy workspace binding_digest
  )

  @doc "Returns the reserved session metadata key."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc "Builds a deterministic string-keyed binding manifest."
  @spec new(Binding.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def new(binding, opts \\ [])

  def new(%Binding{} = binding, opts) when is_list(opts) do
    with {:ok, lock_state} <- lock_state(Keyword.get(opts, :lock_state, :draft)),
         {:ok, draft_generation} <- draft_generation(Keyword.get(opts, :draft_generation, 0)),
         {:ok, lock_operation_id} <- optional_string(Keyword.get(opts, :lock_operation_id)),
         {:ok, command_digest} <- optional_digest(Keyword.get(opts, :first_prompt_command_digest)),
         :ok <- validate_lock_fields(lock_state, lock_operation_id, command_digest),
         {:ok, source_identity} <- portable(binding.source.identity),
         %Record{} = policy_record <- binding.execution_policy.record do
      manifest = %{
        "version" => @version,
        "lock_state" => lock_state,
        "draft_generation" => draft_generation,
        "lock_operation_id" => lock_operation_id,
        "first_prompt_command_digest" => command_digest,
        "source" => %{
          "identity" => source_identity,
          "kind" => Atom.to_string(binding.source.kind),
          "format" => Atom.to_string(binding.source.format),
          "byte_size" => binding.source.byte_size,
          "digest" => binding.source.digest,
          "base_spec_digest" => binding.source.base_spec_digest,
          "agent_id" => binding.source.agent_id,
          "label" => binding.source.label
        },
        "base_spec_digest" => binding.base_spec_digest,
        "bound_spec_digest" => binding.bound_spec_digest,
        "runtime_definition_fingerprint" => binding.runtime_definition_fingerprint,
        "coding_pack" => Jido.Console.Coding.Pack.projection(binding.pack),
        "model" => %{
          "id" => binding.model_id,
          "origin" => Atom.to_string(binding.model_origin)
        },
        "execution_policy" => %{
          "id" => binding.execution_policy.execution_policy_id,
          "profile_digest" => policy_record.security_profile.digest,
          "profile_revision" => policy_record.security_profile.revision,
          "registration_fingerprint" => policy_record.registration_fingerprint
        },
        "workspace" => %{
          "identity" => portable_value(binding.workspace),
          "identity_digest" => workspace_digest(binding.workspace),
          "configuration" => portable_value(binding.workspace_configuration),
          "configuration_digest" => binding.workspace_configuration_digest
        }
      }

      manifest = Map.put(manifest, "binding_digest", binding_digest(manifest))
      validate(manifest)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_binding_manifest_input}
    end
  end

  def new(_binding, _opts), do: {:error, :invalid_binding_manifest_input}

  @doc "Validates manifest shape, full digests, and its binding digest."
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{} = manifest) do
    with :ok <- exact_keys(manifest),
         :ok <- version(manifest["version"]),
         {:ok, _lock_state} <- lock_state(manifest["lock_state"]),
         {:ok, _generation} <- draft_generation(manifest["draft_generation"]),
         {:ok, lock_operation_id} <- optional_string(manifest["lock_operation_id"]),
         {:ok, command_digest} <- optional_digest(manifest["first_prompt_command_digest"]),
         :ok <- validate_lock_fields(manifest["lock_state"], lock_operation_id, command_digest),
         :ok <- validate_source(manifest["source"]),
         :ok <- required_digest(manifest["base_spec_digest"]),
         :ok <- required_digest(manifest["bound_spec_digest"]),
         :ok <- required_digest(manifest["runtime_definition_fingerprint"]),
         :ok <- validate_pack(manifest["coding_pack"]),
         :ok <- validate_model(manifest["model"]),
         :ok <- validate_policy(manifest["execution_policy"]),
         :ok <- validate_workspace(manifest["workspace"]),
         :ok <- required_digest(manifest["binding_digest"]),
         true <- manifest["binding_digest"] == binding_digest(Map.delete(manifest, "binding_digest")) do
      {:ok, manifest}
    else
      false -> {:error, :binding_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def validate(_manifest), do: {:error, :invalid_binding_manifest}

  @doc "Stores a validated manifest without changing unrelated session metadata."
  @spec put(Data.t(), map()) :: {:ok, Data.t()} | {:error, term()}
  def put(%Data{} = session, manifest) do
    with {:ok, manifest} <- validate(manifest) do
      Data.from_input(%{session | metadata: Map.put(session.metadata, @metadata_key, manifest)})
    end
  end

  @doc "Fetches and validates the binding manifest from session metadata."
  @spec fetch(Data.t()) :: {:ok, map()} | {:error, term()}
  def fetch(%Data{metadata: metadata}) do
    case Map.fetch(metadata, @metadata_key) do
      {:ok, manifest} -> validate(manifest)
      :error -> {:error, :binding_manifest_missing}
    end
  end

  @doc "Returns the allowlisted public view without private source or workspace identity."
  @spec safe_projection(map()) :: map()
  def safe_projection(%{} = manifest) do
    source = manifest["source"] || %{}

    %{
      "agent" => %{
        "id" => source["agent_id"],
        "source" => %{
          "kind" => source["kind"],
          "digest" => source["digest"],
          "label" => source["label"]
        }
      },
      "coding_pack" => manifest["coding_pack"],
      "model" => manifest["model"],
      "execution_policy" => %{"id" => get_in(manifest, ["execution_policy", "id"])},
      "workspace" => %{"identity_digest" => get_in(manifest, ["workspace", "identity_digest"])}
    }
  end

  @doc "Computes the version-tagged digest over every field except the digest itself."
  @spec binding_digest(map()) :: String.t()
  def binding_digest(manifest) when is_map(manifest) do
    Digest.semantic(:session_binding_manifest, Map.delete(manifest, "binding_digest"))
  end

  defp exact_keys(manifest) do
    if Enum.sort(Map.keys(manifest)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :invalid_binding_manifest_keys}
  end

  defp version(@version), do: :ok

  defp version(version) when is_integer(version) and version > @version,
    do: {:error, {:unsupported_binding_manifest_version, version}}

  defp version(_version), do: {:error, :invalid_binding_manifest_version}

  defp lock_state(state) when state in [:draft, "draft"], do: {:ok, "draft"}
  defp lock_state(state) when state in [:locked, "locked"], do: {:ok, "locked"}
  defp lock_state(_state), do: {:error, :invalid_binding_lock_state}

  defp draft_generation(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp draft_generation(_value), do: {:error, :invalid_binding_draft_generation}

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_string(_value), do: {:error, :invalid_binding_operation_id}

  defp optional_digest(nil), do: {:ok, nil}

  defp optional_digest(value) do
    case required_digest(value) do
      :ok -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_first_prompt_command_digest}
    end
  end

  defp validate_lock_fields("draft", nil, nil), do: :ok

  defp validate_lock_fields("locked", operation_id, command_digest)
       when is_binary(operation_id) and is_binary(command_digest),
       do: :ok

  defp validate_lock_fields(_state, _operation_id, _command_digest),
    do: {:error, :invalid_binding_lock_fields}

  defp validate_source(%{
         "identity" => identity,
         "kind" => kind,
         "format" => format,
         "byte_size" => byte_size,
         "digest" => digest,
         "base_spec_digest" => base_spec_digest,
         "agent_id" => agent_id,
         "label" => label
       }) do
    with true <- kind in ["builtin", "file"],
         true <- format in ["compiled", "json", "yaml"],
         true <- is_integer(byte_size) and byte_size >= 0,
         true <- is_binary(agent_id) and agent_id != "",
         true <- is_binary(label) and label != "",
         :ok <- required_digest(digest),
         :ok <- required_digest(base_spec_digest),
         {:ok, _identity} <- portable(identity) do
      :ok
    else
      _invalid -> {:error, :invalid_binding_source_evidence}
    end
  end

  defp validate_source(_source), do: {:error, :invalid_binding_source_evidence}

  defp validate_pack(%{"id" => nil, "status" => "disabled"}), do: :ok

  defp validate_pack(%{"id" => id, "status" => "enabled"}) when is_binary(id) and id != "",
    do: :ok

  defp validate_pack(_pack), do: {:error, :invalid_binding_pack_evidence}

  defp validate_model(%{"id" => id, "origin" => origin})
       when is_binary(id) and id != "" and origin in ["agent_spec", "cli", "api", "tui"],
       do: :ok

  defp validate_model(_model), do: {:error, :invalid_binding_model_evidence}

  defp validate_policy(%{
         "id" => id,
         "profile_digest" => profile_digest,
         "profile_revision" => revision,
         "registration_fingerprint" => registration_fingerprint
       }) do
    with true <- is_binary(id) and id != "",
         true <- is_integer(revision) and revision > 0,
         :ok <- required_digest(profile_digest),
         :ok <- required_digest(registration_fingerprint) do
      :ok
    else
      _invalid -> {:error, :invalid_binding_policy_evidence}
    end
  end

  defp validate_policy(_policy), do: {:error, :invalid_binding_policy_evidence}

  defp validate_workspace(%{
         "identity" => identity,
         "identity_digest" => identity_digest,
         "configuration" => configuration,
         "configuration_digest" => configuration_digest
       }) do
    with {:ok, _identity} <- portable(identity),
         {:ok, _configuration} <- portable(configuration),
         :ok <- optional_required_digest(identity_digest),
         :ok <- required_digest(configuration_digest) do
      :ok
    else
      _invalid -> {:error, :invalid_binding_workspace_evidence}
    end
  end

  defp validate_workspace(_workspace), do: {:error, :invalid_binding_workspace_evidence}

  defp optional_required_digest(nil), do: :ok
  defp optional_required_digest(value), do: required_digest(value)

  defp required_digest("sha256:" <> hex) when byte_size(hex) == 64 do
    if hex =~ ~r/\A[0-9a-f]{64}\z/, do: :ok, else: {:error, :invalid_binding_digest}
  end

  defp required_digest(_digest), do: {:error, :invalid_binding_digest}

  defp portable(value) do
    case ExtensionSetup.runtime_definition_fingerprint(value) do
      {:ok, _digest} -> {:ok, portable_value(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp portable_value(nil), do: nil
  defp portable_value(value) when is_atom(value), do: Atom.to_string(value)

  defp portable_value(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, portable_value(item)}
    end)
  end

  defp portable_value(value) when is_list(value), do: Enum.map(value, &portable_value/1)
  defp portable_value(value), do: value

  defp workspace_digest(nil), do: nil

  defp workspace_digest(workspace) do
    Map.get(workspace, :digest, Map.get(workspace, "digest"))
  end
end
