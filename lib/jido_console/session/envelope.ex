defmodule Jido.Console.Session.Envelope do
  @moduledoc "Typed internal envelope for session events and receipts."

  alias Jido.Console.PortableValue

  @families ~w(event receipt)
  @forbidden_authority_sources ~w(renderer transport host origin unknown)
  @limits %{
    "max_identity_bytes" => 256,
    "max_list_items" => 1_000,
    "max_map_keys" => 128,
    "max_text_bytes" => 200_000,
    "max_unknown_bytes" => 4_096,
    "max_unknown_keys" => 16
  }

  @schema Zoi.struct(
            __MODULE__,
            %{
              family: Zoi.enum(@families),
              type: Zoi.string() |> Zoi.min(1),
              id: Zoi.string() |> Zoi.min(1),
              session_id: Zoi.string() |> Zoi.min(1) |> Zoi.nullable(),
              payload: Zoi.map()
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @derive {Jason.Encoder, only: [:family, :type, :id, :session_id, :payload]}
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a session envelope."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the fixed limits used at session boundaries."
  @spec limits() :: map()
  def limits, do: @limits

  @doc "Builds and validates one typed session envelope."
  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(family, type, attrs \\ %{})

  def new(family, type, attrs) when is_map(attrs) do
    id = fetch_value(attrs, "id") || generated_id(family)

    input = %{
      family: family,
      type: type,
      id: id,
      session_id: fetch_value(attrs, "session_id"),
      payload: drop_envelope_fields(attrs)
    }

    validate(input)
  end

  def new(_family, _type, _attrs), do: {:error, :invalid_session_envelope}

  @doc "Validates and normalizes an envelope map or struct."
  @spec validate(t() | map()) :: {:ok, t()} | {:error, term()}
  def validate(value) when is_map(value) do
    with {:ok, envelope} <- parse(value),
         :ok <- reject_authority_source(envelope.payload),
         :ok <- PortableValue.validate(envelope.payload, allow_struct: &(&1 == __MODULE__)),
         :ok <- bound_value(envelope.payload) do
      {:ok, envelope}
    end
  end

  def validate(_value), do: {:error, :invalid_session_envelope}

  @doc "Validates an envelope and blocks materialized secret values."
  @spec validate_final_boundary(t() | map(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def validate_final_boundary(value, materialized_values) when is_list(materialized_values) do
    with {:ok, envelope} <- validate(value),
         :ok <- reject_materialized_values(envelope, materialized_values) do
      {:ok, envelope}
    end
  end

  def validate_final_boundary(_value, _materialized_values),
    do: {:error, :invalid_session_envelope}

  @doc "Converts an envelope and nested envelopes to portable string-key maps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      "family" => envelope.family,
      "type" => envelope.type,
      "id" => envelope.id,
      "session_id" => envelope.session_id,
      "payload" => portable(envelope.payload)
    }
  end

  @doc false
  @spec fetch(t(), atom() | String.t()) :: {:ok, term()} | :error
  def fetch(envelope, key) do
    case field(key) do
      nil -> :error
      field -> Map.fetch(envelope, field)
    end
  end

  @doc false
  @spec get_and_update(t(), atom() | String.t(), (term() -> {term(), term()} | :pop)) ::
          {term(), t()}
  def get_and_update(envelope, key, fun) do
    case field(key) do
      nil -> raise KeyError, key: key, term: envelope
      field -> Map.get_and_update(envelope, field, fun)
    end
  end

  @doc false
  @spec pop(t(), atom() | String.t()) :: {term(), t()}
  def pop(envelope, key) do
    case field(key) do
      nil -> {nil, envelope}
      field -> {Map.get(envelope, field), Map.put(envelope, field, nil)}
    end
  end

  defp parse(%__MODULE__{} = envelope), do: parse_zoi(envelope)

  defp parse(value) do
    input = %{
      family: fetch_value(value, "family"),
      type: fetch_value(value, "type"),
      id: fetch_value(value, "id"),
      session_id: fetch_value(value, "session_id"),
      payload: fetch_value(value, "payload")
    }

    parse_zoi(input)
  end

  defp parse_zoi(value) do
    case Zoi.parse(@schema, value) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, _errors} -> {:error, :invalid_session_envelope}
    end
  end

  defp reject_authority_source(%{"authority_from" => source})
       when source in @forbidden_authority_sources,
       do: {:error, {:authority_from_forbidden, source}}

  defp reject_authority_source(_payload), do: :ok

  defp bound_value(value) when is_binary(value) do
    limit = @limits["max_text_bytes"]

    if byte_size(value) <= limit,
      do: :ok,
      else: {:error, {:oversized_session_value, byte_size(value), limit}}
  end

  defp bound_value(value) when is_list(value) do
    if length(value) <= @limits["max_list_items"] do
      reduce_values(value)
    else
      {:error, :oversized_session_list}
    end
  end

  defp bound_value(%__MODULE__{} = value), do: value |> to_map() |> bound_value()

  defp bound_value(value) when is_map(value) do
    if map_size(value) <= @limits["max_map_keys"] do
      value |> Map.values() |> reduce_values()
    else
      {:error, :oversized_session_map}
    end
  end

  defp bound_value(_value), do: :ok

  defp reduce_values(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case bound_value(value) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_materialized_values(value, materialized_values) do
    secrets = Enum.filter(materialized_values, &(is_binary(&1) and &1 != ""))

    case materialized_value_path(to_map(value), [], secrets) do
      nil ->
        :ok

      path ->
        {:error,
         {:sensitive_result_blocked, :final_boundary,
          %{"path" => Enum.join(path, "."), "reason" => "materialized_value", "redacted" => true}}}
    end
  end

  defp materialized_value_path(value, path, secrets) when is_binary(value) do
    if Enum.any?(secrets, &String.contains?(value, &1)), do: path
  end

  defp materialized_value_path(value, path, secrets) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {item, index} ->
      materialized_value_path(item, path ++ [Integer.to_string(index)], secrets)
    end)
  end

  defp materialized_value_path(value, path, secrets) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      materialized_value_path(item, path ++ [to_string(key)], secrets)
    end)
  end

  defp materialized_value_path(_value, _path, _secrets), do: nil

  defp portable(%__MODULE__{} = envelope), do: to_map(envelope)
  defp portable(value) when is_list(value), do: Enum.map(value, &portable/1)
  defp portable(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, portable(item)} end)
  defp portable(value), do: value

  defp drop_envelope_fields(attrs) do
    Map.drop(attrs, ["id", :id, "session_id", :session_id, "family", :family, "type", :type])
  end

  defp fetch_value(map, key) do
    case field(key) do
      nil -> nil
      field -> Map.get(map, key) || Map.get(map, field)
    end
  end

  defp field(key) when key in [:family, "family"], do: :family
  defp field(key) when key in [:type, "type"], do: :type
  defp field(key) when key in [:id, "id"], do: :id
  defp field(key) when key in [:session_id, "session_id"], do: :session_id
  defp field(key) when key in [:payload, "payload"], do: :payload
  defp field(_key), do: nil

  defp generated_id(family), do: "env_#{family}_#{System.unique_integer([:positive])}"
end
