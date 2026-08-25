defmodule Jido.Console.Session.Event do
  @moduledoc "One ordered Console product-history event."

  @schema_version 1
  @types ~w(
    prompt_queued
    prompt_started
    prompt_removed
    review_presented
    prompt_succeeded
    prompt_failed
    prompt_cancelled
    prompt_interrupted
  )
  @closing_types ~w(prompt_removed prompt_succeeded prompt_failed prompt_cancelled prompt_interrupted)

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string() |> Zoi.min(1),
              session_id: Zoi.string() |> Zoi.min(1),
              queue_item_id: Zoi.string() |> Zoi.min(1),
              request_id: Zoi.string() |> Zoi.min(1),
              type: Zoi.enum(@types),
              schema_version: Zoi.integer() |> Zoi.gte(1) |> Zoi.default(@schema_version),
              jidoka_revision: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(nil),
              payload: Zoi.map(Zoi.string(), Zoi.json(), []) |> Zoi.default(%{}),
              sequence: Zoi.integer() |> Zoi.positive() |> Zoi.optional() |> Zoi.default(nil),
              committed_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(nil)
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the event schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the current event schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the allowed event types."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "Builds one event before storage assigns its sequence and commit time."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs
    |> normalize_keys()
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:payload, %{})
    |> Map.put_new(:jidoka_revision, nil)
    |> Map.put_new(:sequence, nil)
    |> Map.put_new(:committed_at_ms, nil)
    |> parse()
  end

  def new(_attrs), do: {:error, :invalid_thread_event}

  @doc "Builds one event and raises when it is invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid thread event: #{inspect(reason)}"
    end
  end

  @doc "Validates an event struct or map."
  @spec validate(t() | map()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = event), do: event |> Map.from_struct() |> new()
  def validate(event) when is_map(event), do: new(event)
  def validate(_event), do: {:error, :invalid_thread_event}

  @doc "Adds storage-owned fields to a validated event."
  @spec commit(t(), pos_integer(), non_neg_integer()) :: t()
  def commit(%__MODULE__{} = event, sequence, committed_at_ms)
      when is_integer(sequence) and sequence > 0 and is_integer(committed_at_ms) and committed_at_ms >= 0 do
    %__MODULE__{event | sequence: sequence, committed_at_ms: committed_at_ms}
  end

  @doc "Returns true for the first execution event."
  @spec started?(t() | String.t()) :: boolean()
  def started?(%__MODULE__{type: type}), do: started?(type)
  def started?("prompt_started"), do: true
  def started?(_type), do: false

  @doc "Returns true when the event closes a queue item."
  @spec closing?(t() | String.t()) :: boolean()
  def closing?(%__MODULE__{type: type}), do: closing?(type)
  def closing?(type) when is_binary(type), do: type in @closing_types
  def closing?(_type), do: false

  @doc "Returns the canonical fields supplied by the caller."
  @spec identity(t()) :: map()
  def identity(%__MODULE__{} = event) do
    Map.take(event, [
      :id,
      :session_id,
      :queue_item_id,
      :request_id,
      :type,
      :schema_version,
      :jidoka_revision,
      :payload
    ])
  end

  @doc "Converts a safe projected value to canonical JSON data."
  @spec json(term()) :: term()
  def json(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)
  def json(value) when is_list(value), do: Enum.map(value, &json/1)

  def json(%_{} = value), do: value |> Map.from_struct() |> json()

  def json(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_key(key), json(item)} end)
  end

  def json(value) when is_tuple(value), do: value |> Tuple.to_list() |> json()
  def json(value), do: inspect(value, limit: 20, printable_limit: 200)

  @doc "Builds one event for a private thread queue item."
  @spec for_item(map(), map(), String.t(), map(), non_neg_integer() | nil, String.t() | nil) :: t()
  def for_item(state, item, type, payload, revision \\ nil, identity \\ nil) do
    new!(
      id: event_id(state.thread_id, item.id, type, identity),
      session_id: state.thread_id,
      queue_item_id: item.id,
      request_id: item.request_id,
      type: type,
      payload: payload,
      jidoka_revision: revision
    )
  end

  @doc "Builds one globally unique deterministic product event ID."
  @spec event_id(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def event_id(thread_id, queue_item_id, type, identity \\ nil)

  def event_id(thread_id, queue_item_id, type, nil),
    do: Enum.join([thread_id, queue_item_id, type], ":")

  def event_id(thread_id, queue_item_id, type, identity),
    do: Enum.join([thread_id, queue_item_id, type, identity], ":")

  @doc "Projects one stored event into portable View data."
  @spec to_view(t()) :: map()
  def to_view(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.take([
      :id,
      :sequence,
      :queue_item_id,
      :request_id,
      :type,
      :jidoka_revision,
      :payload,
      :committed_at_ms
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp parse(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, %__MODULE__{schema_version: @schema_version} = event} ->
        {:ok, event}

      {:ok, %__MODULE__{schema_version: version}} ->
        {:error, {:unsupported_thread_event_schema, version}}

      {:error, _errors} ->
        {:error, :invalid_thread_event}
    end
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) ->
        case key do
          "id" -> {:id, value}
          "session_id" -> {:session_id, value}
          "queue_item_id" -> {:queue_item_id, value}
          "request_id" -> {:request_id, value}
          "type" -> {:type, value}
          "schema_version" -> {:schema_version, value}
          "jidoka_revision" -> {:jidoka_revision, value}
          "payload" -> {:payload, value}
          "sequence" -> {:sequence, value}
          "committed_at_ms" -> {:committed_at_ms, value}
          _other -> {key, value}
        end

      pair ->
        pair
    end)
  end

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key, limit: 20, printable_limit: 200)
end
