defmodule Jido.Console.Session.ContextProjection do
  @moduledoc "Bounded deterministic model-context projection over immutable canonical history."

  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, Value}
  alias Jido.Console.Storage

  @context_events 256
  @context_bytes 1 * 1_024 * 1_024
  @source_events 1_000
  @source_bytes 8 * 1_024 * 1_024

  @doc "Builds one bounded context projection from the canonical history source range."
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, records} <-
           storage(opts).history_suffix(
             session_id,
             Keyword.merge(opts,
               after_sequence: Keyword.get(opts, :after_sequence, 0),
               limit: @source_events,
               max_bytes: @source_bytes
             )
           ) do
      project(session_id, records, opts)
    end
  end

  @doc "Projects an already verified canonical range without changing its order or content."
  @spec project(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def project(session_id, records, opts \\ [])

  def project(session_id, records, opts) when is_binary(session_id) and is_list(records) do
    max_events = Keyword.get(opts, :context_events, @context_events)
    max_bytes = Keyword.get(opts, :context_bytes, @context_bytes)

    with :ok <- validate_bounds(max_events, max_bytes),
         :ok <- validate_records(records),
         {:ok, selected, encoded_bytes} <- compact(records, max_events, max_bytes),
         {:ok, body, bytes} <- fit_projection(session_id, selected, encoded_bytes, max_bytes),
         :ok <- Value.validate(body),
         true <- byte_size(bytes) <= max_bytes do
      {:ok, Map.put(body, "projection_digest", Digest.portable(bytes))}
    else
      false -> {:error, :context_projection_limit}
      {:error, _reason} = error -> error
    end
  end

  def project(_session_id, _records, _opts), do: {:error, :invalid_context_projection}

  @doc "Returns the hard source and projection limits."
  @spec limits() :: map()
  def limits do
    %{
      context_events: @context_events,
      context_bytes: @context_bytes,
      source_events: @source_events,
      source_bytes: @source_bytes
    }
  end

  defp compact(records, max_events, max_bytes) do
    records
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, [], 0}, fn record, {:ok, selected, bytes} ->
      event = record.event

      case CanonicalJSON.encode(event) do
        {:ok, encoded} ->
          next_bytes = bytes + byte_size(encoded)

          if length(selected) < max_events and next_bytes <= max_bytes do
            {:cont, {:ok, [record | selected], next_bytes}}
          else
            {:halt, {:ok, selected, bytes}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp projection_body(session_id, records, encoded_bytes) do
    source_identity = Enum.map(records, &%{"sequence" => &1.sequence, "record_digest" => &1.record_digest})
    {:ok, source_bytes} = CanonicalJSON.encode(source_identity)

    %{
      "schema" => "jido.console.context-projection",
      "version" => 1,
      "session_id" => session_id,
      "source_start_sequence" => records |> List.first() |> sequence(),
      "source_end_sequence" => records |> List.last() |> sequence(),
      "source_chain_digest" => records |> List.last() |> record_digest(),
      "source_range_digest" => Digest.portable(source_bytes),
      "event_count" => length(records),
      "event_bytes" => encoded_bytes,
      "events" => Enum.map(records, & &1.event)
    }
  end

  defp fit_projection(session_id, records, encoded_bytes, max_bytes) do
    body = projection_body(session_id, records, encoded_bytes)

    with {:ok, bytes} <- CanonicalJSON.encode(body) do
      cond do
        byte_size(bytes) <= max_bytes ->
          {:ok, body, bytes}

        records == [] ->
          {:error, :context_projection_limit}

        true ->
          [removed | rest] = records
          {:ok, removed_bytes} = CanonicalJSON.encode(removed.event)
          fit_projection(session_id, rest, encoded_bytes - byte_size(removed_bytes), max_bytes)
      end
    end
  end

  defp validate_records(records) do
    records
    |> Enum.reduce_while({:ok, nil}, fn record, {:ok, prior_sequence} ->
      cond do
        not valid_record?(record) -> {:halt, {:error, :invalid_context_source_record}}
        prior_sequence && record.sequence != prior_sequence + 1 -> {:halt, {:error, :context_source_gap}}
        true -> {:cont, {:ok, record.sequence}}
      end
    end)
    |> case do
      {:ok, _sequence} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp valid_record?(record) do
    is_map(record) and is_map(record[:event]) and is_integer(record[:sequence]) and record[:sequence] > 0 and
      digest?(record[:record_digest])
  end

  defp validate_bounds(events, bytes)
       when is_integer(events) and events > 0 and events <= @context_events and is_integer(bytes) and bytes > 0 and
              bytes <= @context_bytes,
       do: :ok

  defp validate_bounds(_events, _bytes), do: {:error, :invalid_context_projection_bounds}
  defp sequence(nil), do: nil
  defp sequence(record), do: record.sequence
  defp record_digest(nil), do: "genesis"
  defp record_digest(record), do: record.record_digest

  defp digest?("sha256:" <> value),
    do: byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_value), do: false
  defp storage(opts), do: Keyword.get(opts, :storage, Storage)
end
