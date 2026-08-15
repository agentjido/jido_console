defmodule Jido.Console.Session.Event do
  @moduledoc """
  Classifies Console events without owning live session sequence state.

  The session owner allocates the monotonic sequence and passes it in. This
  module validates classification, identities, and JSON-compatible shape.
  Origin is descriptive data and cannot grant authority.
  """

  alias Jido.Console.Session.{Identity, Protocol}
  alias Jido.Console.Session.Protocol.Validator

  @durabilities ~w(ephemeral process)
  @sensitivities ~w(public redacted secret)
  @origin_kinds ~w(client session worker jidoka system)

  @type t :: map()

  @doc "Classifies one Console event from owner-allocated sequence data."
  @spec classify(map()) :: {:ok, t()} | {:error, term()}
  def classify(attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with :ok <- reject_runtime(attrs),
         :ok <- require_sequence(attrs),
         :ok <- require_class(attrs, "durability", @durabilities),
         :ok <- require_class(attrs, "sensitivity", @sensitivities),
         :ok <- require_origin(attrs),
         :ok <- require_trust(attrs),
         :ok <- preserve_identities(attrs),
         :ok <- reject_origin_authority(attrs),
         {:ok, envelope} <-
           Protocol.envelope(
             schema(),
             "event",
             attrs["type"],
             Map.put(attrs, "id", attrs["id"] || "plt_event_classified")
           ),
         {:ok, validated} <- Validator.validate(envelope) do
      {:ok, validated}
    end
  end

  def classify(_attrs), do: {:error, :invalid_event}

  @doc "Returns true when origin is treated as descriptive data only."
  @spec origin_authority?(map()) :: boolean()
  def origin_authority?(%{"origin" => origin}) when is_map(origin) do
    Identity.authority_source?(origin["kind"]) or origin["authority"] == true
  end

  def origin_authority?(_attrs), do: false

  defp schema do
    {:ok, schema} = Protocol.schema()
    schema
  end

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

  defp preserve_identities(attrs) do
    identities = List.wrap(attrs["identities"])

    if Enum.all?(identities, &valid_identity?/1) do
      :ok
    else
      {:error, :invalid_event_identity}
    end
  end

  defp valid_identity?(%{"kind" => kind, "id" => id, "session_id" => session_id})
       when is_binary(kind) and is_binary(id) and is_binary(session_id) do
    true
  end

  defp valid_identity?(_identity), do: false

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
