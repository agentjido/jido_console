defmodule Jido.Console.Credential.ProfileSchema do
  @moduledoc "Strict secret-free credential profile and reference metadata contract."

  alias Jido.Console.PortableValue
  alias Jido.Console.Storage.CanonicalJSON

  @max_bytes 16 * 1_024

  @profile_fields ~w(profile_id profile_version source_identity references disabled)
  @profile_required ~w(profile_id profile_version source_identity references)
  @reference_fields ~w(reference_id kind source_identity lookup disabled)
  @reference_required ~w(reference_id kind source_identity lookup)
  @lookup_fields %{
    "environment" => ~w(name),
    "private_dotenv" => ~w(file_identity variable),
    "keychain_item" => ~w(item_identity service account)
  }
  @field_errors %{
    credential_profile:
      {:missing_credential_profile_fields, :unknown_credential_profile_fields, :invalid_credential_profile},
    credential_reference:
      {:missing_credential_reference_fields, :unknown_credential_reference_fields, :invalid_credential_reference},
    credential_lookup:
      {:missing_credential_lookup_fields, :unknown_credential_lookup_fields, :invalid_credential_lookup}
  }

  @doc "Validates profile metadata without reading or resolving a credential source."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(profile) when is_map(profile) do
    with :ok <- PortableValue.validate(profile),
         :ok <- exact_fields(profile, @profile_required, @profile_fields, :credential_profile),
         :ok <- validate_profile_identity(profile),
         :ok <- validate_references(profile["references"]),
         {:ok, bytes} <- CanonicalJSON.encode(profile) do
      validate_size(bytes)
    end
  end

  def validate(_profile), do: {:error, :invalid_credential_profile}

  defp validate_profile_identity(profile) do
    cond do
      not non_empty?(profile["profile_id"]) ->
        {:error, :invalid_credential_profile_id}

      not (is_integer(profile["profile_version"]) and profile["profile_version"] > 0) ->
        {:error, :invalid_credential_profile_version}

      not non_empty?(profile["source_identity"]) ->
        {:error, :invalid_credential_source_identity}

      Map.get(profile, "disabled", false) not in [true, false] ->
        {:error, :invalid_credential_profile_status}

      true ->
        :ok
    end
  end

  defp validate_references(references) when is_list(references) and references != [] do
    if length(references) > 8 do
      {:error, :credential_reference_limit}
    else
      references
      |> Enum.reduce_while({:ok, MapSet.new()}, fn reference, {:ok, ids} ->
        with :ok <- exact_fields(reference, @reference_required, @reference_fields, :credential_reference),
             :ok <- validate_reference(reference),
             false <- MapSet.member?(ids, reference["reference_id"]) do
          {:cont, {:ok, MapSet.put(ids, reference["reference_id"])}}
        else
          true -> {:halt, {:error, {:duplicate_credential_reference, reference["reference_id"]}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _ids} -> :ok
        error -> error
      end
    end
  end

  defp validate_references(_references), do: {:error, :invalid_credential_references}

  defp validate_reference(reference) do
    kind = reference["kind"]
    lookup = reference["lookup"]

    cond do
      not non_empty?(reference["reference_id"]) -> {:error, :invalid_credential_reference_id}
      not non_empty?(reference["source_identity"]) -> {:error, :invalid_credential_reference_source}
      kind not in Map.keys(@lookup_fields) -> {:error, {:unsupported_credential_source, kind}}
      not is_map(lookup) -> {:error, :invalid_credential_lookup}
      Map.get(reference, "disabled", false) not in [true, false] -> {:error, :invalid_credential_reference_status}
      true -> validate_lookup(kind, lookup)
    end
  end

  defp validate_lookup(kind, lookup) do
    required = @lookup_fields[kind]

    with :ok <- exact_fields(lookup, required, required, :credential_lookup),
         true <- Enum.all?(required, &(non_empty?(lookup[&1]) and safe_lookup_value?(lookup[&1]))) do
      :ok
    else
      false -> {:error, {:invalid_credential_lookup, kind}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_fields(value, required, fields, label) when is_map(value) do
    {missing_error, unknown_error, _invalid_error} = Map.fetch!(@field_errors, label)
    missing = required -- Map.keys(value)
    unknown = Map.keys(value) -- fields

    cond do
      missing != [] -> {:error, {missing_error, Enum.sort(missing)}}
      unknown != [] -> {:error, {unknown_error, Enum.sort(unknown)}}
      true -> :ok
    end
  end

  defp exact_fields(_value, _required, _fields, label) do
    {_missing_error, _unknown_error, invalid_error} = Map.fetch!(@field_errors, label)
    {:error, invalid_error}
  end

  defp validate_size(bytes) do
    if byte_size(bytes) <= @max_bytes,
      do: :ok,
      else: {:error, {:oversized_credential_metadata, byte_size(bytes), @max_bytes}}
  end

  defp safe_lookup_value?(value) do
    not String.contains?(value, ["=", "?", "#", "${", "--", "\n", "\r"])
  end

  defp non_empty?(value), do: is_binary(value) and value != ""
end
