defmodule Jido.Console.Session.Admission do
  @moduledoc "Atomic idempotent admission for mutating session operations."

  alias Jido.Console.Digest
  alias Jido.Console.PortableValue
  alias Jido.Console.Session.Envelope
  alias Jido.Console.Storage
  alias Jido.Console.Storage.CanonicalJSON

  @idempotency_key_bytes 128
  @admission_schema "1"
  @operation_kinds ~w(send steer queue remove consume_queued invoke start_turn)
  @command_kinds ~w(remove consume_queued invoke)

  @type prepared :: %{
          receipt_id: String.t(),
          operation_id: String.t(),
          session_id: String.t(),
          sequence: pos_integer(),
          operation_kind: String.t(),
          receipt_type: String.t(),
          principal_id: String.t(),
          idempotency_key: String.t(),
          payload_digest: String.t(),
          target_id: String.t(),
          normalized_payload: map()
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

  @doc "Validates one portable admission operation."
  @spec prepare(atom() | String.t(), map(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(kind, payload, opts) when is_map(payload) and is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    principal_id = Keyword.get(opts, :principal_id)
    idempotency_key = Keyword.get(opts, :idempotency_key)
    sequence = Keyword.get(opts, :sequence)

    with {:ok, kind} <- operation_kind(kind),
         :ok <- validate_identity(session_id, :session_id),
         :ok <- validate_identity(principal_id, :principal_id),
         :ok <- validate_idempotency_key(idempotency_key),
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
         :ok <- PortableValue.validate(%{"metadata" => digest_value}),
         {:ok, payload_bytes} <- CanonicalJSON.encode(digest_value) do
      identity = short_digest([session_id, kind, principal_id, idempotency_key])

      {:ok,
       %{
         receipt_id: "receipt_" <> identity,
         operation_id: "admission_" <> identity,
         session_id: session_id,
         sequence: sequence,
         operation_kind: kind,
         receipt_type: if(kind in @command_kinds, do: "command", else: "input"),
         principal_id: principal_id,
         idempotency_key: idempotency_key,
         payload_digest: Digest.portable(payload_bytes),
         target_id: target_id,
         normalized_payload: normalized
       }}
    else
      false -> {:error, :invalid_admission_position}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare(_kind, _payload, _opts), do: {:error, :invalid_admission_payload}

  @doc "Commits one operation and its event in one transaction."
  @spec commit(prepared(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(prepared, event, semantic, _owner, opts \\ []) do
    with {:ok, result} <-
           Storage.admit_operation(
             prepared,
             event,
             semantic,
             storage_opts(opts)
           ),
         {:ok, receipt} <- protocol_receipt(result) do
      {:ok, %{receipt: receipt, duplicate: result.duplicate, durable: result}}
    end
  end

  @doc "Returns one durable admission receipt."
  @spec receipt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def receipt(operation_id, opts \\ []) do
    with {:ok, result} <- Storage.admission_receipt(operation_id, storage_opts(opts)) do
      protocol_receipt(result)
    end
  end

  @doc "Moves one operation to started or terminal state."
  @spec transition(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def transition(operation_id, state, _owner, opts \\ [])

  def transition(operation_id, state, _owner, opts)
      when is_binary(operation_id) and state in ["started", "terminal"] do
    with {:ok, result} <- Storage.transition_admission(operation_id, state, storage_opts(opts)),
         {:ok, receipt} <- protocol_receipt(result) do
      {:ok, %{receipt: receipt, duplicate: result.duplicate, durable: result}}
    end
  end

  def transition(_operation_id, _state, _owner, _opts),
    do: {:error, :invalid_admission_transition}

  @doc "Returns selected operation receipts for restart inspection."
  @spec recover(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recover(session_id, opts \\ []) do
    with {:ok, results} <- Storage.recover_admissions(session_id, storage_opts(opts) ++ recovery_opts(opts)) do
      reduce_receipts(results, [])
    end
  end

  @doc "Returns the fixed admission bounds."
  @spec limits() :: map()
  def limits, do: %{idempotency_key_bytes: @idempotency_key_bytes, operation_kinds: @operation_kinds}

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

  defp protocol_receipt(result) do
    payload = %{
      "operation_id" => result.operation_id,
      "idempotency_key" => result.idempotency_key,
      "payload_digest" => result.payload_digest,
      "sequence" => result.sequence,
      "admission_state" => result.admission_state,
      "durability" => "durable",
      "commit_boundary" => "sqlite_full_commit",
      "status" => "committed"
    }

    payload =
      if result.receipt_type == "command" do
        payload
        |> Map.put("result_id", result.target_id)
        |> Map.put("effective_arguments", result.normalized_payload)
      else
        payload
      end

    Envelope.new(
      "receipt",
      result.receipt_type,
      payload |> Map.put("id", result.receipt_id) |> Map.put("session_id", result.session_id)
    )
  end

  defp reduce_receipts([result | results], receipts) do
    with {:ok, receipt} <- protocol_receipt(result) do
      reduce_receipts(results, [receipt | receipts])
    end
  end

  defp reduce_receipts([], receipts), do: {:ok, Enum.reverse(receipts)}

  defp operation_kind(kind) when is_atom(kind), do: operation_kind(Atom.to_string(kind))
  defp operation_kind(kind) when kind in @operation_kinds, do: {:ok, kind}
  defp operation_kind(_kind), do: {:error, :invalid_admission_operation}

  defp validate_identity(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_identity(_value, field), do: {:error, {:invalid_admission_identity, field}}

  defp normalize(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           {:ok, item} <- normalize(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, normalized} ->
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

  defp storage_opts(opts), do: Keyword.take(opts, [:writer, :deadline])
  defp recovery_opts(opts), do: Keyword.take(opts, [:states, :limit])

  defp short_digest(values) do
    values
    |> Enum.join("\0")
    |> Digest.hex()
  end
end
