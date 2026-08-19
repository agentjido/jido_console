defmodule Jido.Console.Session.Event do
  @moduledoc """
  Classifies Console events without owning live session sequence state.

  The session owner allocates the monotonic sequence and passes it in. This
  module validates classification, identities, and JSON-compatible shape.
  Origin is descriptive data and cannot grant authority.
  """

  alias Jido.Console.Session.{Envelope, Identity}

  @durabilities ~w(ephemeral process)
  @sensitivities ~w(public redacted secret)
  @origin_kinds ~w(client session worker jidoka system)

  @type t :: Envelope.t()

  @doc "Classifies one Console event from owner-allocated sequence data."
  @spec classify(map()) :: {:ok, t()} | {:error, term()}
  def classify(attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with :ok <- reject_deprecated_emission(attrs),
         :ok <- reject_runtime(attrs),
         {:ok, attrs} <- canonicalize_identities(attrs),
         {:ok, envelope} <-
           Envelope.new(
             "event",
             attrs["type"],
             attrs
             |> Map.delete("type")
             |> Map.put("id", attrs["id"] || default_event_id(attrs))
           ) do
      validate(envelope)
    end
  end

  def classify(_attrs), do: {:error, :invalid_event}

  defp reject_deprecated_emission(%{"type" => "delivery_gap"}),
    do: {:error, :deprecated_event_emission}

  defp reject_deprecated_emission(_attrs), do: :ok

  @doc "Validates one classified event envelope and its canonical session identity."
  @spec validate(Envelope.t() | map()) :: {:ok, t()} | {:error, term()}
  def validate(event) when is_map(event) do
    with {:ok, event} <- Envelope.validate(event),
         :ok <- validate_event_semantics(event) do
      {:ok, event}
    end
  end

  def validate(_event), do: {:error, :invalid_event}

  @doc "Returns true when origin is treated as descriptive data only."
  @spec origin_authority?(map()) :: boolean()
  def origin_authority?(%{"origin" => origin}) when is_map(origin) do
    Identity.authority_source?(origin["kind"]) or origin["authority"] == true
  end

  def origin_authority?(_attrs), do: false

  defp require_sequence(%{"sequence" => sequence}) when is_integer(sequence) and sequence >= 0, do: :ok
  defp require_sequence(_attrs), do: {:error, :invalid_event_sequence}

  defp require_class(attrs, field, allowed) do
    if attrs[field] in allowed, do: :ok, else: {:error, {:invalid_event_class, field}}
  end

  defp require_origin(%{"origin" => %{"kind" => kind, "actor_id" => actor_id}})
       when kind in @origin_kinds and is_binary(actor_id) do
    :ok
  end

  defp require_origin(_attrs), do: {:error, :invalid_event_origin}

  defp require_trust(%{"trust" => %{"evidence" => evidence, "policy" => policy}})
       when is_binary(evidence) and is_binary(policy) do
    :ok
  end

  defp require_trust(_attrs), do: {:error, :invalid_event_trust}

  defp canonicalize_identities(%{"session_id" => session_id} = attrs)
       when is_binary(session_id) and session_id != "" do
    with {:ok, identities} <- identities(attrs),
         :ok <- identities_belong_to_session(identities, session_id),
         {:ok, identities} <- ensure_session_identity(identities, session_id) do
      {:ok, Map.put(attrs, "identities", identities)}
    end
  end

  defp canonicalize_identities(_attrs), do: {:error, :invalid_event_session_id}

  defp identities(%{"identities" => identities}) when is_list(identities) do
    if Enum.all?(identities, &valid_identity?/1) do
      {:ok, identities}
    else
      {:error, :invalid_event_identity}
    end
  end

  defp identities(attrs) when not is_map_key(attrs, "identities"), do: {:ok, []}
  defp identities(_attrs), do: {:error, :invalid_event_identity}

  defp identities_belong_to_session(identities, session_id) do
    if Enum.all?(identities, &(&1["session_id"] == session_id)) do
      :ok
    else
      {:error, :event_identity_mismatch}
    end
  end

  defp validate_event_semantics(%Envelope{
         family: "event",
         session_id: session_id,
         payload: payload
       })
       when is_binary(session_id) and session_id != "" and is_map(payload) do
    with :ok <- require_sequence(payload),
         :ok <- require_class(payload, "durability", @durabilities),
         :ok <- require_class(payload, "sensitivity", @sensitivities),
         :ok <- require_origin(payload),
         :ok <- require_trust(payload),
         {:ok, identities} <- identities(payload),
         :ok <- identities_belong_to_session(identities, session_id),
         :ok <- require_session_identity(identities, session_id) do
      reject_origin_authority(payload)
    end
  end

  defp validate_event_semantics(%Envelope{family: "event"}), do: {:error, :invalid_event_session_id}
  defp validate_event_semantics(_event), do: {:error, :invalid_event_envelope}

  defp ensure_session_identity(identities, session_id) do
    case Enum.filter(identities, &(&1["kind"] == "session")) do
      [] ->
        identity = %{"kind" => "session", "id" => session_id, "session_id" => session_id}
        {:ok, [identity | identities]}

      [%{"id" => ^session_id}] ->
        {:ok, identities}

      _other ->
        {:error, :event_identity_mismatch}
    end
  end

  defp require_session_identity(identities, session_id) do
    case Enum.filter(identities, &(&1["kind"] == "session")) do
      [%{"id" => ^session_id}] -> :ok
      [] -> {:error, :event_session_identity_missing}
      _other -> {:error, :event_identity_mismatch}
    end
  end

  defp valid_identity?(%{"kind" => kind, "id" => id, "session_id" => session_id})
       when is_binary(kind) and kind != "" and is_binary(id) and id != "" and is_binary(session_id) and
              session_id != "" do
    true
  end

  defp valid_identity?(_identity), do: false

  defp default_event_id(attrs) do
    type = attrs["type"] || "event"
    sequence = attrs["sequence"] || 0
    "plt_event_#{type}_#{sequence}"
  end

  defp reject_origin_authority(attrs) do
    if origin_authority?(attrs), do: {:error, :origin_cannot_grant_authority}, else: :ok
  end

  defp reject_runtime(value) when is_pid(value) or is_reference(value) or is_function(value) or is_port(value) do
    {:error, :raw_runtime_forbidden}
  end

  defp reject_runtime(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {_key, item}, :ok ->
      case reject_runtime(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_runtime(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case reject_runtime(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_runtime(_value), do: :ok

  defp stringify(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value), do: value
end
