defmodule Jido.Console.Session.Protocol.Validator do
  @moduledoc """
  Validates protocol envelopes against the generated catalog.

  Unknown payload fields are retained only within declared bounds and cannot
  grant authority, permission, or control.
  """

  alias Jido.Console.Session.Protocol.Generated

  @type result :: {:ok, map()} | {:error, term()}

  @doc "Validates one protocol envelope."
  @spec validate(map(), keyword()) :: result()
  def validate(value, opts \\ [])

  def validate(value, opts) when is_map(value) do
    catalog = Keyword.get_lazy(opts, :catalog, &Generated.catalog/0)

    with :ok <- require_envelope(value),
         :ok <- compatible_version(value, catalog),
         :ok <- known_type(value, catalog),
         :ok <- reject_client_local_payload(value, catalog),
         {:ok, payload} <- bound_payload(value["payload"] || %{}, catalog) do
      {:ok, Map.put(value, "payload", payload)}
    end
  end

  def validate(_value, _opts), do: {:error, :invalid_protocol_shape}

  @doc "Validates JSON text as a protocol envelope."
  @spec validate_json(String.t(), keyword()) :: result()
  def validate_json(json, opts \\ []) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> validate(value, opts)
      {:error, reason} -> {:error, {:invalid_protocol_json, reason}}
    end
  end

  defp require_envelope(value) do
    required = ~w(protocol version family type id)

    cond do
      Enum.any?(required, &(not is_binary(value[&1]) or value[&1] == "")) ->
        {:error, :invalid_protocol_envelope}

      value["protocol"] != "jido.session" ->
        {:error, {:invalid_protocol_name, value["protocol"]}}

      true ->
        :ok
    end
  end

  defp compatible_version(%{"version" => version}, catalog) do
    if version == catalog["version"] do
      :ok
    else
      {:error, {:incompatible_protocol_version, version}}
    end
  end

  defp known_type(%{"family" => family, "type" => type}, catalog) do
    case get_in(catalog, ["families", family, "types", type]) do
      declaration when is_map(declaration) -> :ok
      _other -> {:error, {:unknown_protocol_type, family, type}}
    end
  end

  defp reject_client_local_payload(%{"family" => family, "type" => type, "payload" => payload}, catalog)
       when is_map(payload) do
    declaration = get_in(catalog, ["families", family, "types", type])
    local_fields = MapSet.new(catalog["client_local_fields"] || [])

    cond do
      declaration["locality"] != "shared" ->
        :ok

      Enum.any?(Map.keys(payload), &MapSet.member?(local_fields, &1)) ->
        {:error, :client_local_forbidden}

      true ->
        :ok
    end
  end

  defp reject_client_local_payload(%{"payload" => payload}, _catalog) when not is_map(payload) do
    {:error, :invalid_protocol_payload}
  end

  defp reject_client_local_payload(_value, _catalog), do: :ok

  defp bound_payload(payload, catalog) when is_map(payload) do
    bounds = catalog["bounds"]
    authority = catalog["authority"]
    unknown_limit = bounds["max_unknown_bytes"]
    unknown_keys = bounds["max_unknown_keys"]
    known = known_field_set(catalog)

    with :ok <- bound_value(payload, bounds),
         :ok <- reject_unknown_authority(payload, known, authority) do
      unknown =
        payload
        |> Map.drop(MapSet.to_list(known))
        |> Map.drop(authority_fields(authority))

      cond do
        map_size(unknown) > unknown_keys ->
          {:error, :unknown_data_overflow}

        encoded_size(unknown) > unknown_limit ->
          {:error, :unknown_data_overflow}

        true ->
          {:ok, payload}
      end
    end
  end

  defp bound_payload(_payload, _catalog), do: {:error, :invalid_protocol_payload}

  defp bound_value(value, bounds) when is_binary(value) do
    limit = bounds["max_text_bytes"]

    if byte_size(value) <= limit do
      :ok
    else
      {:error, {:oversized_protocol_value, byte_size(value), limit}}
    end
  end

  defp bound_value(value, bounds) when is_list(value) do
    if length(value) <= bounds["max_list_items"] do
      Enum.reduce_while(value, :ok, fn item, :ok ->
        case bound_value(item, bounds) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :oversized_protocol_list}
    end
  end

  defp bound_value(value, bounds) when is_map(value) do
    if map_size(value) <= bounds["max_map_keys"] do
      Enum.reduce_while(value, :ok, fn {_key, item}, :ok ->
        case bound_value(item, bounds) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :oversized_protocol_map}
    end
  end

  defp bound_value(_value, _bounds), do: :ok

  defp reject_unknown_authority(payload, known, authority) do
    forbidden = MapSet.new(authority_fields(authority))

    leaked =
      payload
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.filter(&MapSet.member?(forbidden, &1))

    if leaked == [], do: :ok, else: {:error, {:unknown_authority_field, leaked}}
  end

  defp known_field_set(catalog) do
    catalog["families"]
    |> Enum.flat_map(fn {_family, entry} ->
      entry
      |> Map.get("types", %{})
      |> Enum.flat_map(fn {_name, declaration} -> List.wrap(declaration["fields"]) end)
    end)
    |> MapSet.new()
    |> MapSet.union(
      MapSet.new(
        ~w(sequence durability sensitivity origin trust unknown content view reason text attachments arguments)
      )
    )
  end

  defp authority_fields(%{"authority_fields" => fields}) when is_list(fields), do: fields
  defp authority_fields(_authority), do: []

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _reason} -> 0
    end
  end
end
