defmodule Jido.Console.Session.Queue do
  @moduledoc "Bounded FIFO prompts for one thread owner."

  @default_limit 32

  @schema Zoi.struct(
            __MODULE__,
            %{
              items: Zoi.array() |> Zoi.default([]),
              limit: Zoi.integer() |> Zoi.positive() |> Zoi.default(@default_limit)
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type item :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type t :: %__MODULE__{items: [item()], limit: pos_integer()}

  @doc "Creates an empty queue."
  @spec new(pos_integer()) :: t()
  def new(limit \\ @default_limit) when is_integer(limit) and limit > 0 do
    %__MODULE__{limit: limit}
  end

  @doc "Adds one item to the FIFO tail."
  @spec push(t(), item()) :: {:ok, t()} | {:error, :queue_full | :invalid_queue_item | {:queue_item_exists, String.t()}}
  def push(%__MODULE__{} = queue, item) do
    with {:ok, id} <- item_id(item),
         false <- full?(queue),
         false <- Enum.any?(queue.items, &(item_id!(&1) == id)) do
      {:ok, %{queue | items: queue.items ++ [item]}}
    else
      true when length(queue.items) >= queue.limit -> {:error, :queue_full}
      true -> {:error, {:queue_item_exists, item_id!(item)}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Takes the FIFO head."
  @spec pop(t()) :: {:ok, item(), t()} | {:error, :queue_empty}
  def pop(%__MODULE__{items: [item | rest]} = queue), do: {:ok, item, %{queue | items: rest}}
  def pop(%__MODULE__{}), do: {:error, :queue_empty}

  @doc "Removes one item by ID. Missing IDs are successful no-ops."
  @spec remove(t(), String.t()) :: {:ok, item() | nil, t()}
  def remove(%__MODULE__{} = queue, id) when is_binary(id) and id != "" do
    case Enum.split_while(queue.items, &(item_id!(&1) != id)) do
      {before, [item | after_items]} -> {:ok, item, %{queue | items: before ++ after_items}}
      {_before, []} -> {:ok, nil, queue}
    end
  end

  @doc "Returns true when no pending slot remains."
  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{} = queue), do: length(queue.items) >= queue.limit

  @doc "Returns the pending item count."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = queue), do: length(queue.items)

  @doc "Returns items in FIFO order."
  @spec to_list(t()) :: [item()]
  def to_list(%__MODULE__{} = queue), do: queue.items

  defp item_id(%{id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp item_id(_item), do: {:error, :invalid_queue_item}

  defp item_id!(item) do
    {:ok, id} = item_id(item)
    id
  end
end
