defmodule Jido.Console.Session.Durable.CanonicalJSON do
  @moduledoc "Canonical JSON with recursive lexical object-key order."

  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Encodes one JSON value with recursive lexical map-key order."
  @spec encode(term()) :: result(binary())
  def encode(value) do
    with {:ok, ordered} <- order(value) do
      case Jason.encode_to_iodata(ordered, maps: :strict) do
        {:ok, encoded} -> {:ok, IO.iodata_to_binary(encoded)}
        {:error, reason} -> {:error, {:invalid_json_value, reason}}
      end
    end
  end

  @doc "Decodes JSON and requires its bytes to be canonical."
  @spec decode(binary()) :: result(term())
  def decode(encoded) when is_binary(encoded) do
    with {:ok, value} <- decode_json(encoded),
         {:ok, canonical} <- encode(value),
         true <- canonical == encoded do
      {:ok, value}
    else
      false -> {:error, :noncanonical_json}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_encoded), do: {:error, :invalid_json_bytes}

  defp decode_json(encoded) do
    case Jason.decode(encoded) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp order(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp order(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, items} ->
      case order(item) do
        {:ok, ordered} -> {:cont, {:ok, [ordered | items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp order(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn
      {key, item}, {:ok, items} when is_binary(key) ->
        case order(item) do
          {:ok, ordered} -> {:cont, {:ok, [{key, ordered} | items]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {_key, _item}, _acc ->
        {:halt, {:error, :non_string_json_key}}
    end)
    |> then(fn
      {:ok, items} -> {:ok, items |> Enum.sort_by(&elem(&1, 0)) |> Jason.OrderedObject.new()}
      error -> error
    end)
  end

  defp order(value) when is_struct(value), do: {:error, {:forbidden_runtime_value, :struct}}
  defp order(value) when is_pid(value), do: {:error, {:forbidden_runtime_value, :pid}}
  defp order(value) when is_reference(value), do: {:error, {:forbidden_runtime_value, :reference}}
  defp order(value) when is_port(value), do: {:error, {:forbidden_runtime_value, :port}}
  defp order(value) when is_function(value), do: {:error, {:forbidden_runtime_value, :function}}
  defp order(_value), do: {:error, :non_json_value}
end
