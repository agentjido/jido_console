defmodule Jido.Console.Session.Durable.WatermarkRecord do
  @moduledoc "Strict state and identity validation for Console-to-Jidoka watermarks."

  @states ~w(reserved jidoka_committed console_committed verified repair_required abandoned)
  @transitions %{
    nil => ["reserved"],
    "reserved" => ~w(jidoka_committed repair_required abandoned),
    "jidoka_committed" => ~w(console_committed repair_required abandoned),
    "console_committed" => ~w(verified repair_required abandoned),
    "repair_required" => ~w(jidoka_committed console_committed abandoned),
    "verified" => [],
    "abandoned" => []
  }

  @console_fields ~w(session_id generation sequence event_id operation_id chain_digest)
  @jidoka_fields ~w(session_id revision request_id lease_id snapshot_id operation_id value_digest)

  @doc "Returns the closed watermark state inventory."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Validates one durable watermark payload."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{
        "watermark_id" => watermark_id,
        "console_identity" => console,
        "console_digest" => console_digest,
        "jidoka_identity" => jidoka,
        "jidoka_digest" => jidoka_digest,
        "state" => state
      }) do
    with :ok <- non_empty(watermark_id, :watermark_id),
         :ok <- allowed_state(state),
         :ok <- identity(console, @console_fields, :console),
         :ok <- identity(jidoka, @jidoka_fields, :jidoka),
         true <- console["chain_digest"] == console_digest,
         true <- jidoka["value_digest"] == jidoka_digest,
         true <- valid_mapping?(console, jidoka) do
      :ok
    else
      false -> {:error, :watermark_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def validate(_payload), do: {:error, :invalid_watermark_payload}

  @doc "Validates one append-only state transition."
  @spec validate_transition(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def validate_transition(previous, next) do
    if next in Map.get(@transitions, previous, []) do
      :ok
    else
      {:error, {:invalid_watermark_transition, previous, next}}
    end
  end

  defp identity(value, fields, kind) when is_map(value) do
    missing = fields -- Map.keys(value)

    cond do
      missing != [] -> {:error, {:missing_watermark_identity_fields, kind, Enum.sort(missing)}}
      not Enum.all?(fields, &valid_identity_field?(&1, value[&1])) -> {:error, {:invalid_watermark_identity, kind}}
      true -> :ok
    end
  end

  defp identity(_value, _fields, kind), do: {:error, {:invalid_watermark_identity, kind}}

  defp valid_identity_field?(field, value) when field in ["generation", "sequence", "revision"],
    do: is_integer(value) and value >= 0

  defp valid_identity_field?(field, value) when field in ["chain_digest", "value_digest"],
    do: valid_digest?(value)

  defp valid_identity_field?(_field, value), do: is_binary(value) and value != ""

  defp valid_mapping?(console, jidoka) do
    console["session_id"] == jidoka["session_id"] or jidoka["mapping_kind"] in ["imported", "forked"]
  end

  defp allowed_state(state) when state in @states, do: :ok
  defp allowed_state(state), do: {:error, {:invalid_watermark_state, state}}
  defp non_empty(value, _field) when is_binary(value) and value != "", do: :ok
  defp non_empty(_value, field), do: {:error, {:invalid_watermark_field, field}}

  defp valid_digest?("sha256:" <> digest),
    do: byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_value), do: false
end
