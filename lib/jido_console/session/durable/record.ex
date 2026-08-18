defmodule Jido.Console.Session.Durable.Record do
  @moduledoc "Strict canonical Console record codec and digest-chain validation."

  alias Jido.Console.Digest

  alias Jido.Console.Session.Durable.{
    CanonicalJSON,
    Catalog,
    CredentialProfile,
    EffectRecord,
    TurnManifest,
    Value,
    WatermarkRecord
  }

  @record_schema "jido.console.record"
  @record_schema_version 1
  @store_format_version 1
  @envelope_fields ~w(
    record_schema
    record_schema_version
    store_format_version
    record_type
    record_id
    scope_id
    generation
    sequence
    prior_record_digest
    payload
  )

  @type encoded :: %{
          record: map(),
          bytes: binary(),
          digest: String.t(),
          encoded_bytes: non_neg_integer()
        }

  @doc "Returns a new record envelope with current schema identities."
  @spec new(String.t(), map(), keyword()) :: map()
  def new(type, payload, opts) when is_binary(type) and is_map(payload) and is_list(opts) do
    %{
      "record_schema" => @record_schema,
      "record_schema_version" => @record_schema_version,
      "store_format_version" => @store_format_version,
      "record_type" => type,
      "record_id" => Keyword.fetch!(opts, :record_id),
      "scope_id" => Keyword.fetch!(opts, :scope_id),
      "generation" => Keyword.get(opts, :generation, 0),
      "sequence" => Keyword.get(opts, :sequence, 0),
      "prior_record_digest" => Keyword.get(opts, :prior_record_digest, "genesis"),
      "payload" => payload
    }
  end

  @doc "Validates and encodes one record into canonical bytes."
  @spec encode(map()) :: {:ok, encoded()} | {:error, term()}
  def encode(record) when is_map(record) do
    with :ok <- Value.validate(record),
         :ok <- validate_envelope(record),
         {:ok, declaration} <- Catalog.record_type(record["record_type"]),
         :ok <- validate_payload(record["payload"], declaration),
         :ok <- validate_specialized_payload(record["record_type"], record["payload"]),
         {:ok, bytes} <- CanonicalJSON.encode(record),
         :ok <- validate_size(bytes) do
      {:ok,
       %{
         record: record,
         bytes: bytes,
         digest: Digest.portable(bytes),
         encoded_bytes: byte_size(bytes)
       }}
    end
  end

  def encode(_record), do: {:error, :invalid_record}

  @doc "Decodes canonical bytes and returns the verified digest and byte count."
  @spec decode(binary()) :: {:ok, encoded()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, record} <- CanonicalJSON.decode(bytes),
         {:ok, encoded} <- encode(record),
         true <- encoded.bytes == bytes do
      {:ok, encoded}
    else
      false -> {:error, :noncanonical_record}
      {:error, :noncanonical_json} -> {:error, :noncanonical_record}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_bytes), do: {:error, :invalid_record_bytes}

  @doc "Verifies supplied digests, sequence order, and prior-record links."
  @spec verify_chain([map()]) :: :ok | {:error, term()}
  def verify_chain(records) when is_list(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, "genesis", nil}, fn {item, index}, {:ok, prior, prior_sequence} ->
      case verify_item(item, index, prior, prior_sequence) do
        {:ok, digest, sequence} -> {:cont, {:ok, digest, sequence}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _digest, _sequence} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_chain(_records), do: {:error, :invalid_record_chain}

  defp verify_item(item, index, expected_prior, prior_sequence) when is_map(item) do
    bytes = item[:bytes] || item["bytes"]
    supplied_digest = item[:digest] || item["digest"]
    supplied_id = item[:record_id] || item["record_id"] || "index:#{index}"

    case decode(bytes) do
      {:ok, encoded} ->
        record = encoded.record
        id = record["record_id"] || supplied_id

        cond do
          supplied_digest != encoded.digest ->
            invalid(id, :record_digest_mismatch)

          record["prior_record_digest"] != expected_prior ->
            invalid(id, {:prior_record_digest_mismatch, expected_prior})

          not next_sequence?(prior_sequence, record["sequence"]) ->
            invalid(id, {:record_sequence_mismatch, prior_sequence})

          true ->
            {:ok, encoded.digest, record["sequence"]}
        end

      {:error, reason} ->
        invalid(supplied_id, reason)
    end
  end

  defp verify_item(_item, index, _expected_prior, _prior_sequence),
    do: invalid("index:#{index}", :invalid_record_chain_item)

  defp validate_envelope(record) do
    with :ok <- validate_envelope_fields(record),
         :ok <- validate_envelope_versions(record) do
      validate_envelope_values(record)
    end
  end

  defp validate_envelope_fields(record) do
    missing = @envelope_fields -- Map.keys(record)
    unknown = Map.keys(record) -- @envelope_fields

    cond do
      missing != [] -> {:error, {:missing_record_fields, Enum.sort(missing)}}
      unknown != [] -> {:error, {:unknown_record_fields, Enum.sort(unknown)}}
      true -> :ok
    end
  end

  defp validate_envelope_versions(record) do
    cond do
      record["record_schema"] != @record_schema -> {:error, :incompatible_record_schema}
      record["record_schema_version"] != @record_schema_version -> {:error, :incompatible_record_schema}
      record["store_format_version"] > @store_format_version -> {:error, :incompatible_future_store_format}
      record["store_format_version"] != @store_format_version -> {:error, :incompatible_store_format}
      true -> :ok
    end
  end

  defp validate_envelope_values(record) do
    cond do
      not non_empty?(record["record_id"]) -> {:error, :invalid_record_id}
      not non_empty?(record["scope_id"]) -> {:error, :invalid_record_scope}
      not non_negative?(record["generation"]) -> {:error, :invalid_record_generation}
      not non_negative?(record["sequence"]) -> {:error, :invalid_record_sequence}
      not valid_prior?(record["prior_record_digest"]) -> {:error, :invalid_prior_record_digest}
      not is_map(record["payload"]) -> {:error, :invalid_record_payload}
      true -> :ok
    end
  end

  defp validate_payload(payload, declaration) when is_map(payload) do
    fields = declaration["fields"]
    missing = declaration["required"] -- Map.keys(payload)
    unknown = Map.keys(payload) -- fields

    cond do
      missing != [] -> {:error, {:missing_record_payload_fields, Enum.sort(missing)}}
      unknown != [] -> {:error, {:unknown_record_payload_fields, Enum.sort(unknown)}}
      true -> validate_payload_types(payload)
    end
  end

  defp validate_payload_types(payload) do
    Enum.reduce_while(payload, :ok, fn {field, value}, :ok ->
      with {:ok, type} <- Catalog.field_type(field),
           true <- valid_field_type?(value, type) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:invalid_record_payload_type, field}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_specialized_payload("credential_profile_reference", payload),
    do: CredentialProfile.validate(payload)

  defp validate_specialized_payload("turn_manifest", payload), do: TurnManifest.validate(payload)

  defp validate_specialized_payload("effect_reservation", payload),
    do: EffectRecord.validate_reservation(payload)

  defp validate_specialized_payload("effect_resolution", payload),
    do: EffectRecord.validate_resolution(payload)

  defp validate_specialized_payload("verified_watermark", payload),
    do: WatermarkRecord.validate(payload)

  defp validate_specialized_payload(_record_type, _payload), do: :ok

  defp valid_field_type?(value, "string"), do: is_binary(value) and value != ""
  defp valid_field_type?(value, "string_or_null"), do: is_nil(value) or valid_field_type?(value, "string")
  defp valid_field_type?(value, "integer"), do: is_integer(value) and value >= 0
  defp valid_field_type?(value, "integer_or_null"), do: is_nil(value) or valid_field_type?(value, "integer")
  defp valid_field_type?(value, "boolean"), do: is_boolean(value)
  defp valid_field_type?(value, "map"), do: is_map(value) and not is_struct(value)
  defp valid_field_type?(value, "map_or_null"), do: is_nil(value) or valid_field_type?(value, "map")
  defp valid_field_type?(value, "list"), do: is_list(value)
  defp valid_field_type?(value, "digest"), do: valid_digest?(value)
  defp valid_field_type?("genesis", "digest_or_genesis"), do: true
  defp valid_field_type?(value, "digest_or_genesis"), do: valid_digest?(value)
  defp valid_field_type?(nil, "digest_or_null"), do: true
  defp valid_field_type?(value, "digest_or_null"), do: valid_digest?(value)
  defp valid_field_type?(_value, "json"), do: true
  defp valid_field_type?(_value, _type), do: false

  defp validate_size(bytes) do
    {:ok, limit} = Catalog.limit("console_record_bytes")
    if byte_size(bytes) <= limit, do: :ok, else: {:error, {:oversized_record, byte_size(bytes), limit}}
  end

  defp next_sequence?(nil, sequence), do: sequence >= 0
  defp next_sequence?(prior, sequence), do: sequence == prior + 1

  defp valid_prior?("genesis"), do: true
  defp valid_prior?(value), do: valid_digest?(value)

  defp valid_digest?("sha256:" <> digest),
    do: byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_value), do: false

  defp non_empty?(value), do: is_binary(value) and value != ""
  defp non_negative?(value), do: is_integer(value) and value >= 0
  defp invalid(id, reason), do: {:error, {:invalid_record, id, reason}}
end
