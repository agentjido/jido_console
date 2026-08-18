defmodule Jido.Console.Session.AuditProjection do
  @moduledoc "Portable redacted audit projection and offline digest-chain verification."

  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, Record, Value}

  @record_limit 10_000
  @export_bytes 8 * 1_024 * 1_024

  @doc "Builds a portable audit view from complete authoritative record chains."
  @spec export([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def export(records, opts \\ [])

  def export(records, opts) when is_list(records) do
    with :ok <- validate_source(records),
         :ok <- scan(records, Keyword.get(opts, :forbidden_values, [])),
         {:ok, entries, head} <- build_entries(records, opts),
         export = %{
           "schema" => "jido.console.audit-projection",
           "version" => 1,
           "entry_count" => length(entries),
           "head_digest" => head,
           "entries" => entries
         },
         :ok <- Value.validate(export),
         {:ok, bytes} <- CanonicalJSON.encode(export),
         :ok <- export_size(bytes) do
      {:ok, Map.put(export, "export_digest", Digest.portable(bytes))}
    end
  end

  def export(_records, _opts), do: {:error, :invalid_audit_source}

  @doc "Verifies an exported view offline and detects mutation, deletion, insertion, or reorder."
  @spec verify(map()) :: :ok | {:error, term()}
  def verify(
        %{
          "schema" => "jido.console.audit-projection",
          "version" => 1,
          "entries" => entries,
          "entry_count" => count,
          "head_digest" => head,
          "export_digest" => export_digest
        } = export
      )
      when is_list(entries) and count == length(entries) do
    with {:ok, verified_head} <- verify_entries(entries),
         true <- verified_head == head,
         unsigned = Map.delete(export, "export_digest"),
         {:ok, bytes} <- CanonicalJSON.encode(unsigned),
         true <- Digest.portable(bytes) == export_digest do
      :ok
    else
      false -> {:error, :audit_projection_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def verify(_export), do: {:error, :invalid_audit_projection}

  @doc "Recursively rejects runtime values, credential structures, and explicit canary values."
  @spec scan(term(), [binary()]) :: :ok | {:error, term()}
  def scan(value, forbidden_values) when is_list(forbidden_values) do
    with :ok <- Value.validate(value) do
      case find_forbidden(value, forbidden_values, []) do
        nil -> :ok
        path -> {:error, {:forbidden_audit_value, %{"path" => Enum.join(path, "."), "redacted" => true}}}
      end
    end
  end

  defp validate_source(records) when length(records) <= @record_limit do
    records
    |> Enum.group_by(&scope_id/1)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {_scope, chain}, :ok ->
      case Record.verify_chain(chain) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_audit_source_chain, reason}}}
      end
    end)
  rescue
    _exception -> {:error, :invalid_audit_source}
  end

  defp validate_source(_records), do: {:error, {:audit_record_limit, @record_limit}}

  defp build_entries(records, opts) do
    records
    |> Enum.sort_by(&{scope_id(&1), sequence(&1)})
    |> Enum.reduce_while({:ok, [], "genesis"}, fn encoded, {:ok, entries, prior} ->
      with {:ok, entry} <- audit_entry(encoded, prior, opts),
           {:ok, bytes} <- CanonicalJSON.encode(entry) do
        digest = Digest.portable(bytes)
        {:cont, {:ok, [Map.put(entry, "audit_digest", digest) | entries], digest}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, entries, head} -> {:ok, Enum.reverse(entries), head}
      {:error, _reason} = error -> error
    end)
  end

  defp audit_entry(encoded, prior, opts) do
    with {:ok, record, digest} <- decoded(encoded),
         {:ok, payload} <- portable_payload(record["payload"]) do
      {:ok,
       %{
         "record_id" => record["record_id"],
         "record_type" => record["record_type"],
         "scope_id" => record["scope_id"],
         "generation" => record["generation"],
         "sequence" => record["sequence"],
         "record_digest" => digest,
         "prior_audit_digest" => prior,
         "origin" => record["payload"]["origin"],
         "trust" => record["payload"]["trust"],
         "watermark" => Keyword.get(opts, :watermark),
         "fork" => Keyword.get(opts, :fork),
         "payload" => payload
       }}
    end
  end

  defp decoded(%{record: record, digest: digest}) when is_map(record), do: {:ok, record, digest}

  defp decoded(%{"record" => record, "digest" => digest}) when is_map(record),
    do: {:ok, record, digest}

  defp decoded(_encoded), do: {:error, :invalid_audit_source_record}

  defp portable_payload(payload) do
    payload
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, result} ->
      if is_map(value) or is_list(value) do
        case CanonicalJSON.encode(value) do
          {:ok, bytes} -> {:cont, {:ok, Map.put(result, key <> "_digest", Digest.portable(bytes))}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, Map.put(result, key, value)}}
      end
    end)
  end

  defp verify_entries(entries) do
    Enum.reduce_while(entries, {:ok, "genesis"}, fn entry, {:ok, prior} ->
      supplied = entry["audit_digest"]
      unsigned = Map.delete(entry, "audit_digest")

      with true <- entry["prior_audit_digest"] == prior,
           {:ok, bytes} <- CanonicalJSON.encode(unsigned),
           true <- Digest.portable(bytes) == supplied do
        {:cont, {:ok, supplied}}
      else
        _invalid -> {:halt, {:error, {:audit_chain_mismatch, entry["record_id"]}}}
      end
    end)
  end

  defp find_forbidden(value, forbidden, path) when is_binary(value) do
    if Enum.any?(forbidden, &(&1 != "" and String.contains?(value, &1))), do: path, else: nil
  end

  defp find_forbidden(value, forbidden, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {item, index} -> find_forbidden(item, forbidden, path ++ [Integer.to_string(index)]) end)
  end

  defp find_forbidden(value, forbidden, path) when is_map(value) and not is_struct(value) do
    Enum.find_value(value, fn {key, item} ->
      item_path = path ++ [to_string(key)]
      find_forbidden(to_string(key), forbidden, item_path) || find_forbidden(item, forbidden, item_path)
    end)
  end

  defp find_forbidden(_value, _forbidden, _path), do: nil

  defp export_size(bytes) when byte_size(bytes) <= @export_bytes, do: :ok
  defp export_size(bytes), do: {:error, {:audit_export_limit, byte_size(bytes), @export_bytes}}
  defp scope_id(encoded), do: encoded.record["scope_id"]
  defp sequence(encoded), do: encoded.record["sequence"]
end
