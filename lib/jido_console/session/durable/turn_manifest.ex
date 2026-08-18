defmodule Jido.Console.Session.Durable.TurnManifest do
  @moduledoc "Strict validation for durable turn and invocation identity metadata."

  @identity_fields ~w(
    request_id invocation_id provider_id model_id variant_id coding_profile_id workspace_id
  )
  @digest_fields ~w(
    settings_digest agent_spec_digest prompt_digest tool_schema_digest skill_schema_digest
    extension_descriptor_digest protocol_digest workspace_digest
  )
  @credential_fields ~w(
    credential_profile_id credential_profile_version credential_reference_id credential_source_identity
  )

  @doc "Validates exact identity fields and the all-or-none credential selection."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(manifest) when is_map(manifest) do
    with :ok <- validate_strings(manifest),
         :ok <- validate_digests(manifest),
         :ok <- validate_execution_environment(manifest) do
      validate_credential_selection(manifest)
    end
  end

  def validate(_manifest), do: {:error, :invalid_turn_manifest}

  defp validate_strings(manifest) do
    if Enum.all?(@identity_fields, &non_empty?(manifest[&1])),
      do: :ok,
      else: {:error, :invalid_turn_manifest_identity}
  end

  defp validate_digests(manifest) do
    if Enum.all?(@digest_fields, &digest?(manifest[&1])),
      do: :ok,
      else: {:error, :invalid_turn_manifest_digest}
  end

  defp validate_execution_environment(%{"execution_environment_id" => value})
       when is_nil(value) or (is_binary(value) and value != ""),
       do: :ok

  defp validate_execution_environment(_manifest), do: {:error, :invalid_execution_environment_identity}

  defp validate_credential_selection(manifest) do
    values = Map.take(manifest, @credential_fields)

    cond do
      Enum.all?(@credential_fields, &is_nil(values[&1])) ->
        :ok

      non_empty?(values["credential_profile_id"]) and
        is_integer(values["credential_profile_version"]) and values["credential_profile_version"] > 0 and
        non_empty?(values["credential_reference_id"]) and non_empty?(values["credential_source_identity"]) ->
        :ok

      true ->
        {:error, :invalid_turn_manifest_credential_selection}
    end
  end

  defp digest?("sha256:" <> value),
    do: byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_value), do: false
  defp non_empty?(value), do: is_binary(value) and value != ""
end
