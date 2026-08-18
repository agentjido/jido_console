defmodule Jido.Console.Session.Durable.SemanticSnapshot do
  @moduledoc "Strict codec for bounded, derived semantic session snapshots."

  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, Value}
  alias Jido.Console.Session.State

  @schema "jido.console.semantic-snapshot"
  @version 1
  @max_bytes 1_048_576
  @fields ~w(schema version snapshot_id session_id generation source_sequence source_chain_digest reason state)
  @state_fields_v1 ~w(session_id sequence queues active_run)
  @state_fields @state_fields_v1 ++ ~w(pending_interactions permissions control_state)
  @reasons ~w(interval suffix_bytes terminal approval_wait hibernation fork archive manual)

  @type encoded :: %{
          value: map(),
          bytes: binary(),
          digest: String.t(),
          encoded_bytes: pos_integer()
        }

  @doc "Builds and encodes one snapshot without canonical event history."
  @spec encode(String.t(), State.t(), map(), String.t()) :: {:ok, encoded()} | {:error, term()}
  def encode(snapshot_id, state, head, reason) do
    value = %{
      "schema" => @schema,
      "version" => @version,
      "snapshot_id" => snapshot_id,
      "session_id" => state.session_id,
      "generation" => head.generation,
      "source_sequence" => head.sequence,
      "source_chain_digest" => head.chain_digest,
      "reason" => reason,
      "state" => compact_state(state)
    }

    encode(value)
  end

  @doc "Validates and encodes an existing snapshot value."
  @spec encode(map()) :: {:ok, encoded()} | {:error, term()}
  def encode(value) when is_map(value) do
    with :ok <- Value.validate(value),
         :ok <- validate(value),
         {:ok, bytes} <- CanonicalJSON.encode(value),
         :ok <- bounded(bytes) do
      {:ok, %{value: value, bytes: bytes, digest: Digest.portable(bytes), encoded_bytes: byte_size(bytes)}}
    end
  end

  def encode(_value), do: {:error, :invalid_semantic_snapshot}

  @doc "Decodes canonical bytes and verifies the supplied digest."
  @spec decode(binary(), String.t()) :: {:ok, encoded()} | {:error, term()}
  def decode(bytes, digest) when is_binary(bytes) and is_binary(digest) do
    with {:ok, value} <- CanonicalJSON.decode(bytes),
         {:ok, encoded} <- encode(value),
         true <- encoded.bytes == bytes,
         true <- encoded.digest == digest do
      {:ok, encoded}
    else
      false -> {:error, :semantic_snapshot_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_bytes, _digest), do: {:error, :invalid_semantic_snapshot}

  @doc "Restores the compact renderer-neutral state from a verified snapshot."
  @spec restore(encoded()) :: {:ok, State.t()} | {:error, term()}
  def restore(%{value: %{"state" => state}}) do
    restored = %{
      session_id: state["session_id"],
      sequence: state["sequence"],
      history: [],
      queues: %{
        steering: get_in(state, ["queues", "steering"]),
        follow_up: get_in(state, ["queues", "follow_up"])
      },
      pending_interactions: state["pending_interactions"] || %{},
      permissions: state["permissions"] || %{},
      control_state: state["control_state"] || %{},
      active_run: state["active_run"]
    }

    with :ok <- State.validate(restored), do: {:ok, restored}
  end

  def restore(_encoded), do: {:error, :invalid_semantic_snapshot}

  @doc "Returns the fixed snapshot byte limit."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defp compact_state(state) do
    %{
      "session_id" => state.session_id,
      "sequence" => state.sequence,
      "queues" => %{
        "steering" => state.queues.steering,
        "follow_up" => state.queues.follow_up
      },
      "pending_interactions" => Map.get(state, :pending_interactions, %{}),
      "permissions" => Map.get(state, :permissions, %{}),
      "control_state" => Map.get(state, :control_state, %{}),
      "active_run" => state.active_run
    }
  end

  defp validate(value) do
    with :ok <- validate_envelope(value),
         :ok <- validate_position(value),
         :ok <- validate_snapshot_state(value) do
      State.validate(value["state"])
    end
  end

  defp validate_envelope(value) do
    cond do
      Enum.sort(Map.keys(value)) != Enum.sort(@fields) ->
        {:error, :invalid_semantic_snapshot_fields}

      value["schema"] != @schema or value["version"] != @version ->
        {:error, :incompatible_semantic_snapshot}

      not token?(value["snapshot_id"]) or not token?(value["session_id"]) ->
        {:error, :invalid_semantic_snapshot_identity}

      value["reason"] not in @reasons ->
        {:error, :invalid_semantic_snapshot_reason}

      true ->
        :ok
    end
  end

  defp validate_position(value) do
    cond do
      not positive?(value["generation"]) or not non_negative?(value["source_sequence"]) ->
        {:error, :invalid_semantic_snapshot_position}

      not digest?(value["source_chain_digest"]) ->
        {:error, :invalid_semantic_snapshot_chain}

      true ->
        :ok
    end
  end

  defp validate_snapshot_state(value) do
    state = value["state"]

    cond do
      not is_map(state) or
          Enum.sort(Map.keys(state)) not in [Enum.sort(@state_fields_v1), Enum.sort(@state_fields)] ->
        {:error, :invalid_semantic_snapshot_state}

      state["session_id"] != value["session_id"] or state["sequence"] != value["source_sequence"] ->
        {:error, :semantic_snapshot_identity_mismatch}

      not valid_queues?(state["queues"]) ->
        {:error, :invalid_semantic_snapshot_state}

      true ->
        :ok
    end
  end

  defp valid_queues?(%{"steering" => steering, "follow_up" => follow_up} = queues),
    do: map_size(queues) == 2 and is_list(steering) and is_list(follow_up)

  defp valid_queues?(_queues), do: false

  defp bounded(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp bounded(bytes), do: {:error, {:semantic_snapshot_too_large, byte_size(bytes), @max_bytes}}
  defp token?(value), do: is_binary(value) and value != "" and byte_size(value) <= 256
  defp positive?(value), do: is_integer(value) and value > 0
  defp non_negative?(value), do: is_integer(value) and value >= 0

  defp digest?("sha256:" <> value),
    do: byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_value), do: false
end
