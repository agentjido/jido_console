defmodule Jido.Console.Session.Queue do
  @moduledoc """
  Separate steering and follow-up input queues.
  """

  @kinds [:steering, :follow_up]

  @type t :: %{steering: [map()], follow_up: [map()]}

  @doc "Returns empty queues."
  @spec new() :: t()
  def new, do: %{steering: [], follow_up: []}

  @doc "Adds one identity-bound item to a queue."
  @spec add(t(), atom(), map()) :: {:ok, t()} | {:error, term()}
  def add(queues, kind, item) when kind in @kinds do
    if valid_item?(item) do
      {:ok, Map.update!(queues, kind, &(&1 ++ [item]))}
    else
      {:error, :invalid_queue_item}
    end
  end

  def add(_queues, kind, _item), do: {:error, {:unknown_queue, kind}}

  @doc "Removes one item by input identity."
  @spec remove(t(), atom(), String.t()) :: {:ok, t()} | {:error, term()}
  def remove(queues, kind, input_id) when kind in @kinds do
    {:ok, Map.update!(queues, kind, &Enum.reject(&1, fn item -> item_id(item) == input_id end))}
  end

  def remove(_queues, kind, _input_id), do: {:error, {:unknown_queue, kind}}

  @doc "Consumes the next item from one queue."
  @spec consume(t(), atom()) :: {:ok, map(), t()} | {:error, term()}
  def consume(queues, kind) when kind in @kinds do
    case queues[kind] do
      [item | rest] -> {:ok, item, Map.put(queues, kind, rest)}
      [] -> {:error, :queue_empty}
    end
  end

  def consume(_queues, kind), do: {:error, {:unknown_queue, kind}}

  @doc "Returns items from one queue."
  @spec show(t(), atom()) :: {:ok, [map()]} | {:error, term()}
  def show(queues, kind) when kind in @kinds, do: {:ok, queues[kind]}
  def show(_queues, kind), do: {:error, {:unknown_queue, kind}}

  defp valid_item?(item) do
    is_map(item) and present?(item, :session_id) and present?(item, :input_id) and present?(item, :client_id)
  end

  defp item_id(item), do: field(item, :input_id)

  defp present?(item, key), do: is_binary(field(item, key))

  defp field(item, key), do: item[key] || item[Atom.to_string(key)]
end
