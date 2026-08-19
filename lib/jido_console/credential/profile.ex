defmodule Jido.Console.Credential.Profile do
  @moduledoc "Versioned, immutable, and secret-free credential profile operations."

  alias Jido.Console.Credential.Resolver
  alias Jido.Console.Credential.ProfileSchema
  alias Jido.Console.Storage

  @profile_limit 128

  @type selection :: %{
          profile_id: String.t(),
          profile_version: pos_integer(),
          reference_id: String.t(),
          source_identity: String.t()
        }

  @doc "Creates version one of an immutable profile."
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(profile, opts \\ [])

  def create(profile, opts) when is_map(profile) do
    with :ok <- validate_profile(profile),
         :ok <- require_version(profile, 1),
         {:ok, []} <- history(profile["profile_id"], opts) do
      append(profile, nil, opts)
    else
      {:ok, _records} -> {:error, {:credential_profile_exists, profile["profile_id"]}}
      {:error, _reason} = error -> error
    end
  end

  def create(_profile, _opts), do: {:error, :invalid_credential_profile}

  @doc "Appends the exact next immutable profile version."
  @spec new_version(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def new_version(profile, opts \\ [])

  def new_version(profile, opts) when is_map(profile) do
    with :ok <- validate_profile(profile),
         {:ok, records} <- history(profile["profile_id"], opts),
         {:ok, latest} <- latest_record(records, profile["profile_id"]),
         :ok <- require_version(profile, latest.profile["profile_version"] + 1),
         :ok <- stable_profile_identity(latest.profile, profile) do
      append(profile, latest, opts)
    end
  end

  def new_version(_profile, _opts), do: {:error, :invalid_credential_profile}

  @doc "Disables a profile by appending a new immutable version."
  @spec disable(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable(profile_id, opts \\ []) when is_binary(profile_id) do
    with {:ok, records} <- history(profile_id, opts),
         {:ok, latest} <- latest_record(records, profile_id) do
      profile = latest.profile

      if Map.get(profile, "disabled", false) do
        {:ok, Map.put(redacted(profile), :duplicate, true)}
      else
        profile
        |> Map.put("profile_version", profile["profile_version"] + 1)
        |> Map.put("disabled", true)
        |> new_version(opts)
      end
    end
  end

  @doc "Disables one reference by appending a new immutable profile version."
  @spec disable_reference(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_reference(profile_id, reference_id, opts \\ [])
      when is_binary(profile_id) and is_binary(reference_id) do
    with {:ok, records} <- history(profile_id, opts),
         {:ok, latest} <- latest_record(records, profile_id),
         profile = latest.profile,
         {:ok, reference} <- exact_reference(profile, reference_id) do
      if Map.get(reference, "disabled", false) do
        {:ok, Map.put(redacted(profile), :duplicate, true)}
      else
        references =
          Enum.map(profile["references"], fn
            %{"reference_id" => ^reference_id} = item -> Map.put(item, "disabled", true)
            item -> item
          end)

        profile
        |> Map.put("profile_version", profile["profile_version"] + 1)
        |> Map.put("references", references)
        |> new_version(opts)
      end
    end
  end

  @doc "Lists the latest redacted version of each profile."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, records} <- storage(opts).credential_profiles(opts) do
      records = Enum.take(records, @profile_limit)
      {:ok, records |> Enum.map(&redacted(&1.profile)) |> Enum.sort_by(& &1.profile_id)}
    end
  end

  @doc "Shows the latest redacted profile version without resolving a source."
  @spec show(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def show(profile_id, opts \\ []) when is_binary(profile_id) and is_list(opts) do
    with {:ok, records} <- history(profile_id, opts),
         {:ok, latest} <- latest_record(records, profile_id) do
      {:ok, redacted(latest.profile)}
    end
  end

  @doc "Shows one exact redacted profile version."
  @spec show(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def show(profile_id, version, opts) when is_binary(profile_id) and is_integer(version) and version > 0 do
    with {:ok, encoded} <- load_version(profile_id, version, opts) do
      {:ok, redacted(encoded.profile)}
    end
  end

  @doc "Returns redacted profile and reference status without source resolution."
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(profile_id, opts \\ []) do
    with {:ok, profile} <- show(profile_id, opts) do
      {:ok,
       %{
         profile_id: profile.profile_id,
         profile_version: profile.profile_version,
         source_identity: profile.source_identity,
         status: if(profile.disabled, do: :disabled, else: :active),
         references: profile.references
       }}
    end
  end

  @doc "Selects one active reference by identity without reading a credential value."
  @spec select(String.t(), keyword()) :: {:ok, selection()} | {:error, term()}
  def select(profile_id, opts \\ []) when is_binary(profile_id) do
    version = Keyword.get(opts, :profile_version)

    with {:ok, encoded} <- load_selected_version(profile_id, version, opts),
         profile = encoded.profile,
         :ok <- profile_enabled(profile),
         {:ok, reference} <- select_reference(profile, Keyword.get(opts, :reference_id)) do
      {:ok,
       %{
         profile_id: profile["profile_id"],
         profile_version: profile["profile_version"],
         reference_id: reference["reference_id"],
         source_identity: reference["source_identity"]
       }}
    end
  end

  @doc "Checks one exact recorded selection without resolving its external source."
  @spec compatibility(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def compatibility(selection, opts \\ [])

  def compatibility(selection, opts) when is_map(selection) do
    with {:ok, normalized} <- normalize_selection(selection),
         {:ok, encoded} <- load_version(normalized.profile_id, normalized.profile_version, opts),
         {:ok, records} <- history(normalized.profile_id, opts),
         {:ok, latest} <- latest_record(records, normalized.profile_id),
         profile = encoded.profile,
         current = latest.profile,
         :ok <- profile_enabled(current),
         {:ok, current_reference} <- exact_reference(current, normalized.reference_id),
         :ok <- reference_enabled(current_reference),
         :ok <- same_source_identity(current_reference, normalized.source_identity),
         :ok <- profile_enabled(profile),
         {:ok, reference} <- exact_reference(profile, normalized.reference_id),
         :ok <- reference_enabled(reference),
         :ok <- same_source_identity(reference, normalized.source_identity) do
      {:ok, Map.put(normalized, :status, :compatible)}
    end
  end

  def compatibility(_selection, _opts), do: {:error, :invalid_credential_selection}

  @doc "Materializes the exact selected source only within a provider or tool callback."
  @spec materialize(map(), (binary() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def materialize(selection, callback, opts \\ [])

  def materialize(selection, callback, opts) when is_map(selection) and is_function(callback, 1) do
    with {:ok, compatible} <- compatibility(selection, opts),
         {:ok, encoded} <- load_version(compatible.profile_id, compatible.profile_version, opts),
         {:ok, reference} <- exact_reference(encoded.profile, compatible.reference_id) do
      Resolver.materialize(reference, callback, opts)
    end
  end

  def materialize(_selection, _callback, _opts), do: {:error, :invalid_credential_materialization}

  defp append(profile, _prior, opts) do
    with {:ok, operation_id} <- operation_id(opts),
         {:ok, result} <- storage(opts).put_credential_profile(profile, operation_id, storage_opts(opts)) do
      {:ok,
       redacted(profile)
       |> Map.put(:digest, result.digest)
       |> Map.put(:duplicate, result.duplicate)}
    end
  end

  defp history(profile_id, opts) do
    if valid_id?(profile_id) do
      storage(opts).credential_profile_history(profile_id, storage_opts(opts))
    else
      {:error, :invalid_credential_profile_id}
    end
  end

  defp load_selected_version(profile_id, nil, opts) do
    with {:ok, records} <- history(profile_id, opts), do: latest_record(records, profile_id)
  end

  defp load_selected_version(profile_id, version, opts), do: load_version(profile_id, version, opts)

  defp load_version(profile_id, version, opts) do
    with {:ok, records} <- history(profile_id, opts) do
      case Enum.find(records, &(&1.profile["profile_version"] == version)) do
        nil -> {:error, {:credential_profile_version_not_found, profile_id, version}}
        encoded -> {:ok, encoded}
      end
    end
  end

  defp latest_record([], profile_id), do: {:error, {:credential_profile_not_found, profile_id}}
  defp latest_record(records, _profile_id), do: {:ok, List.last(records)}

  defp validate_profile(profile) do
    with :ok <- ProfileSchema.validate(profile),
         true <- valid_id?(profile["profile_id"]),
         true <- Enum.all?(profile["references"], &valid_id?(&1["reference_id"])),
         true <- Enum.all?(profile["references"], &(&1["source_identity"] == profile["source_identity"])) do
      :ok
    else
      false -> {:error, :invalid_credential_profile_identity}
      {:error, _reason} = error -> error
    end
  end

  defp require_version(%{"profile_version" => expected}, expected), do: :ok

  defp require_version(%{"profile_version" => actual}, expected),
    do: {:error, {:credential_profile_version_conflict, expected, actual}}

  defp stable_profile_identity(previous, candidate) do
    with true <- previous["profile_id"] == candidate["profile_id"],
         true <- previous["source_identity"] == candidate["source_identity"],
         :ok <- stable_references(previous["references"], candidate["references"]) do
      :ok
    else
      false -> {:error, :credential_profile_identity_changed}
      {:error, _reason} = error -> error
    end
  end

  defp stable_references(previous, candidate) do
    previous_by_id = Map.new(previous, &{&1["reference_id"], &1})
    candidate_ids = MapSet.new(candidate, & &1["reference_id"])
    missing = previous_by_id |> Map.keys() |> Enum.reject(&MapSet.member?(candidate_ids, &1))

    if missing == [] do
      Enum.reduce_while(candidate, :ok, fn reference, :ok ->
        case stable_reference(previous_by_id, reference) do
          :ok ->
            {:cont, :ok}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    else
      {:error, {:credential_reference_removed, Enum.sort(missing)}}
    end
  end

  defp stable_reference(previous_by_id, reference) do
    case Map.get(previous_by_id, reference["reference_id"]) do
      nil ->
        :ok

      prior ->
        stable = Map.take(prior, ["kind", "source_identity", "lookup"])
        current = Map.take(reference, ["kind", "source_identity", "lookup"])

        if stable == current, do: :ok, else: {:error, :credential_reference_identity_changed}
    end
  end

  defp profile_enabled(%{"disabled" => true, "profile_id" => id, "profile_version" => version}),
    do: {:error, {:credential_profile_disabled, id, version}}

  defp profile_enabled(_profile), do: :ok

  defp select_reference(profile, nil) do
    case Enum.find(profile["references"], &(not Map.get(&1, "disabled", false))) do
      nil -> {:error, {:credential_source_unavailable, %{profile_id: profile["profile_id"]}}}
      reference -> {:ok, reference}
    end
  end

  defp select_reference(profile, reference_id) when is_binary(reference_id) do
    with {:ok, reference} <- exact_reference(profile, reference_id),
         :ok <- reference_enabled(reference) do
      {:ok, reference}
    end
  end

  defp select_reference(_profile, _reference_id), do: {:error, :invalid_credential_reference_id}

  defp exact_reference(profile, reference_id) do
    case Enum.find(profile["references"], &(&1["reference_id"] == reference_id)) do
      nil -> {:error, {:credential_reference_not_found, profile["profile_id"], reference_id}}
      reference -> {:ok, reference}
    end
  end

  defp reference_enabled(%{"disabled" => true, "reference_id" => id}),
    do: {:error, {:credential_reference_disabled, id}}

  defp reference_enabled(_reference), do: :ok

  defp same_source_identity(%{"source_identity" => identity}, identity), do: :ok

  defp same_source_identity(%{"reference_id" => id}, _identity),
    do: {:error, {:credential_source_identity_changed, id}}

  defp normalize_selection(selection) do
    normalized = %{
      profile_id: selection[:profile_id] || selection["profile_id"],
      profile_version: selection[:profile_version] || selection["profile_version"],
      reference_id: selection[:reference_id] || selection["reference_id"],
      source_identity: selection[:source_identity] || selection["source_identity"]
    }

    if valid_id?(normalized.profile_id) and is_integer(normalized.profile_version) and
         normalized.profile_version > 0 and valid_id?(normalized.reference_id) and
         is_binary(normalized.source_identity) and normalized.source_identity != "" do
      {:ok, normalized}
    else
      {:error, :invalid_credential_selection}
    end
  end

  defp redacted(profile) do
    %{
      profile_id: profile["profile_id"],
      profile_version: profile["profile_version"],
      source_identity: profile["source_identity"],
      disabled: Map.get(profile, "disabled", false),
      references:
        Enum.map(profile["references"], fn reference ->
          %{
            reference_id: reference["reference_id"],
            kind: reference["kind"],
            source_identity: reference["source_identity"],
            disabled: Map.get(reference, "disabled", false)
          }
        end)
    }
  end

  defp operation_id(opts) do
    case Keyword.get(opts, :operation_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :operation_id_required}
    end
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, value)
  defp storage_opts(opts), do: Keyword.take(opts, [:writer, :deadline])
  defp storage(opts), do: Keyword.get(opts, :storage, Storage)
end
