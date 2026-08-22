defmodule Jido.Console.Session.QueueContractTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Queue

  test "keeps one FIFO order" do
    queue = Queue.new(3)
    assert {:ok, queue} = Queue.push(queue, %{id: "one", input: "first"})
    assert {:ok, queue} = Queue.push(queue, %{id: "two", input: "second"})
    assert {:ok, queue} = Queue.push(queue, %{id: "three", input: "third"})

    assert Enum.map(Queue.to_list(queue), & &1.id) == ~w(one two three)
    assert Queue.size(queue) == 3
    assert Queue.full?(queue)

    assert {:ok, %{id: "one"}, queue} = Queue.pop(queue)
    assert {:ok, %{id: "two"}, queue} = Queue.pop(queue)
    assert {:ok, %{id: "three"}, queue} = Queue.pop(queue)
    assert {:error, :queue_empty} = Queue.pop(queue)
  end

  test "returns queue_full without changing existing order" do
    queue = Queue.new(2)
    assert {:ok, queue} = Queue.push(queue, %{id: "one"})
    assert {:ok, queue} = Queue.push(queue, %{id: "two"})

    assert {:error, :queue_full} = Queue.push(queue, %{id: "three"})
    assert Enum.map(Queue.to_list(queue), & &1.id) == ~w(one two)
  end

  test "removes a middle item and makes repeated removal a no-op" do
    queue = Queue.new(3)
    assert {:ok, queue} = Queue.push(queue, %{id: "one"})
    assert {:ok, queue} = Queue.push(queue, %{id: "two"})
    assert {:ok, queue} = Queue.push(queue, %{id: "three"})

    assert {:ok, %{id: "two"}, queue} = Queue.remove(queue, "two")
    assert Enum.map(Queue.to_list(queue), & &1.id) == ~w(one three)

    assert {:ok, nil, same_queue} = Queue.remove(queue, "two")
    assert same_queue == queue
  end

  test "rejects invalid and duplicate item identities" do
    queue = Queue.new()
    assert {:error, :invalid_queue_item} = Queue.push(queue, %{input: "missing id"})
    assert {:ok, queue} = Queue.push(queue, %{id: "same", input: "first"})
    assert {:error, {:queue_item_exists, "same"}} = Queue.push(queue, %{id: "same", input: "second"})
  end
end
