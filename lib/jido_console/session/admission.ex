defmodule Jido.Console.Session.Admission do
  @moduledoc "Restart-safe admission receipts for mutating session operations."

  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, Record, Value}
  alias Jido.Console.Session.{Generation, Protocol}
  alias Jido.Console.Storage

  @idempotency_key_bytes 128
  @admission_schema "1"
  @operation_kinds ~w(send steer queue remove consume_queued invoke start_turn)

  @type prepared :: %{
          receipt_id: String.t(),
          operation_id: String.t(),
          operation_kind: String.t(),
          receipt_type: String.t(),
          principal_id: String.t(),
          idempotency_key: String.t(),
          payload_digest: String.t(),
          target_id: String.t(),
          normalized_payload: map(),
          encoded: Record.encoded()
        }

  @doc "Returns the stable target identity for one caller idempotency key."
  @spec target_id(String.t(), atom() | String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def target_id(session_id, kind, principal_id, idempotency_key) do
    with {:ok, kind} <- operation_kind(kind),
         :ok <- validate_identity(session_id, :session_id),
         :ok <- validate_identity(principal_id, :principal_id),
         :ok <- validate_idempotency_key(idempotency_key) do
      prefix = if kind == "invoke", do: "cmd", else: "inp"
      {:ok, prefix <> "_" <> short_digest([session_id, kind, principal_id, idempotency_key])}
    end
  end

  @doc "Validates and encodes one secret-free durable admission receipt."
  @spec prepare(atom() | String.t(), map(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(kind, payload, opts) when is_map(payload) and is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    principal_id = Keyword.get(opts, :principal_id)
    idempotency_key = Keyword.get(opts, :idempotency_key)
    generation = Keyword.get(opts, :generation)
    sequence = Keyword.get(opts, :sequence)

    with {:ok, kind} <- operation_kind(kind),
         :ok <- validate_identity(session_id, :session_id),
         :ok <- validate_identity(principal_id, :principal_id),
         :ok <- validate_idempotency_key(idempotency_key),
         true <- is_integer(generation) and generation > 0,
         true <- is_integer(sequence) and sequence > 0,
         {:ok, target_id} <- target_id(session_id, kind, principal_id, idempotency_key),
         {:ok, normalized} <- normalize(payload),
         digest_value = %{
           "schema" => @admission_schema,
           "operation_kind" => kind,
           "principal_id" => principal_id,
           "target_id" => target_id,
           "payload" => normalized
         },
         :ok <- Value.validate(%{"metadata" => digest_value}),
         {:ok, payload_bytes} <- CanonicalJSON.encode(digest_value),
         payload_digest = Digest.portable(payload_bytes),
         identity = short_digest([session_id, kind, principal_id, idempotency_key]),
         receipt_id = "receipt_" <> identity,
         operation_id = "admission_" <> identity,
         {receipt_type, receipt_payload} =
           receipt_record(kind, normalized, operation_id, idempotency_key, payload_digest, target_id, principal_id),
         record =
           Record.new(
             receipt_type,
             receipt_payload,
             record_id: receipt_id,
             scope_id: session_id,
             generation: generation,
             sequence: sequence,
             prior_record_digest: "genesis"
           ),
         {:ok, encoded} <- Record.encode(record) do
      {:ok,
       %{
         receipt_id: receipt_id,
         operation_id: operation_id,
         operation_kind: kind,
         receipt_type: receipt_type,
         principal_id: principal_id,
         idempotency_key: idempotency_key,
         payload_digest: payload_digest,
         target_id: target_id,
         normalized_payload: normalized,
         encoded: encoded
       }}
    else
      false -> {:error, :invalid_admission_position}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare(_kind, _payload, _opts), do: {:error, :invalid_admission_payload}

  @doc "Atomically commits one receipt and its canonical admission event."
  @spec commit(prepared(), map(), map(), Generation.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def commit(prepared, event, semantic, fence, opts \\ []) do
    operation_fence = Generation.for_operation(fence, prepared.operation_id)

    with {:ok, result} <-
           Storage.admit_operation(
             prepared,
             event,
             semantic,
             storage_opts(opts, prepared.operation_id, operation_fence)
           ),
         {:ok, receipt} <- protocol_receipt(result) do
      {:ok, %{receipt: receipt, duplicate: result.duplicate, durable: result}}
    end
  end

  @doc "Returns one exact durable admission receipt by operation identity."
  @spec receipt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def receipt(operation_id, opts \\ []) do
    with {:ok, result} <- Storage.admission_receipt(operation_id, opts) do
      protocol_receipt(result)
    end
  end

  @doc "Moves one durable admission to started or terminal state."
  @spec transition(String.t(), String.t(), Generation.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transition(operation_id, state, fence, opts \\ [])

  def transition(operation_id, state, fence, opts)
      when is_binary(operation_id) and state in ["started", "terminal"] and is_map(fence) do
    transition_operation_id = operation_id <> ":" <> state
    operation_fence = Generation.for_operation(fence, transition_operation_id)

    with {:ok, result} <-
           Storage.transition_admission(
             operation_id,
             state,
             storage_opts(opts, transition_operation_id, operation_fence)
           ),
         {:ok, receipt} <- protocol_receipt(result) do
      {:ok, %{receipt: receipt, duplicate: result.duplicate, durable: result}}
    end
  end

  def transition(_operation_id, _state, _fence, _opts),
    do: {:error, :invalid_admission_transition}

  @doc "Returns accepted, started, or terminal receipts for restart recovery."
  @spec recover(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recover(session_id, opts \\ []) do
    with {:ok, results} <- Storage.recover_admissions(session_id, opts) do
      Enum.reduce_while(results, {:ok, []}, fn result, {:ok, receipts} ->
        case protocol_receipt(result) do
          {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Returns the fixed public receipt bounds."
  @spec limits() :: map()
  def limits, do: %{idempotency_key_bytes: @idempotency_key_bytes, operation_kinds: @operation_kinds}

  defp receipt_record(kind, normalized, operation_id, key, _digest, target_id, principal_id)
       when kind in ~w(remove consume_queued invoke) do
    command_id = normalized["command_id"] || kind

    {"command_receipt",
     %{
       "operation_id" => operation_id,
       "idempotency_key" => key,
       "command_id" => command_id,
       "effective_arguments" => normalized,
       "result_id" => target_id,
       "principal_id" => principal_id
     }}
  end

  defp receipt_record(_kind, _normalized, operation_id, key, digest, target_id, principal_id) do
    {"input_receipt",
     %{
       "operation_id" => operation_id,
       "idempotency_key" => key,
       "payload_digest" => digest,
       "input_id" => target_id,
       "admission_state" => "accepted",
       "principal_id" => principal_id
     }}
  end

  defp protocol_receipt(%{record: record} = result) do
    type = if record["record_type"] == "command_receipt", do: "command", else: "input"

    payload =
      case type do
        "command" ->
          %{
            "operation_id" => result.operation_id,
            "idempotency_key" => result.idempotency_key,
            "payload_digest" => result.payload_digest,
            "result_id" => record["payload"]["result_id"],
            "effective_arguments" => record["payload"]["effective_arguments"],
            "sequence" => result.sequence,
            "admission_state" => result.admission_state,
            "durability" => "durable",
            "commit_boundary" => "sqlite_full_commit",
            "status" => "committed"
          }

        "input" ->
          %{
            "operation_id" => result.operation_id,
            "idempotency_key" => result.idempotency_key,
            "payload_digest" => result.payload_digest,
            "sequence" => result.sequence,
            "admission_state" => result.admission_state,
            "durability" => "durable",
            "commit_boundary" => "sqlite_full_commit",
            "status" => "committed"
          }
      end

    with {:ok, schema} <- Protocol.schema() do
      Protocol.envelope(
        schema,
        "receipt",
        type,
        payload |> Map.put("id", result.receipt_id) |> Map.put("session_id", result.session_id)
      )
    end
  end

  defp operation_kind(kind) when is_atom(kind), do: operation_kind(Atom.to_string(kind))

  defp operation_kind(kind) when kind in @operation_kinds, do: {:ok, kind}
  defp operation_kind(_kind), do: {:error, :invalid_admission_operation}

  @doc "Validates one bounded caller idempotency key."
  @spec validate_idempotency_key(term()) :: :ok | {:error, term()}
  def validate_idempotency_key(value) when is_binary(value) do
    cond do
      value == "" ->
        {:error, :idempotency_key_required}

      not String.valid?(value) ->
        {:error, :invalid_idempotency_key}

      byte_size(value) > @idempotency_key_bytes ->
        {:error, {:idempotency_key_too_large, byte_size(value), @idempotency_key_bytes}}

      String.trim(value) != value ->
        {:error, :invalid_idempotency_key}

      true ->
        :ok
    end
  end

  def validate_idempotency_key(_value), do: {:error, :idempotency_key_required}

  defp validate_identity(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_identity(_value, field), do: {:error, {:invalid_admission_identity, field}}

  defp normalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           {:ok, item} <- normalize(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, normalized} ->
      case normalize(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(value)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize(_value), do: {:error, :nonportable_admission_payload}

  defp normalize_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_admission_payload_key}

  defp storage_opts(opts, operation_id, fence) do
    opts
    |> Keyword.take([:writer, :quota, :admission, :deadline])
    |> Keyword.put(:operation_id, operation_id)
    |> Keyword.put(:fence, fence)
  end

  defp short_digest(values) do
    values
    |> Enum.join("\0")
    |> Digest.hex()
  end
end
