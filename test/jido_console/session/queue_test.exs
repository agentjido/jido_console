defmodule Jido.Console.Session.QueueTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Queue}

  test "steering and follow-up use separate operations" do
    item = %{session_id: Identity.new!(:session).id, input_id: "inp_1", client_id: "cli_1"}
    {:ok, queues} = Queue.add(Queue.new(), :steering, item)
    {:ok, _queues} = Queue.add(queues, :follow_up, %{item | input_id: "inp_2"})
    {:ok, [steering]} = Queue.show(queues, :steering)
    assert steering.input_id == "inp_1"
    assert {:ok, ^steering, %{steering: []}} = Queue.consume(queues, :steering)
    assert {:error, {:unknown_queue, :other}} = Queue.consume(queues, :other)

    string_item = %{"session_id" => item.session_id, "input_id" => "inp_3", "client_id" => "cli_1"}
    {:ok, queues} = Queue.add(Queue.new(), :follow_up, string_item)
    {:ok, emptied} = Queue.remove(queues, :follow_up, "inp_3")
    assert emptied.follow_up == []

    assert {:error, :invalid_queue_item} = Queue.add(Queue.new(), :steering, %{})
    assert {:error, {:unknown_queue, :other}} = Queue.add(Queue.new(), :other, item)
    assert {:error, {:unknown_queue, :other}} = Queue.remove(Queue.new(), :other, "inp_1")
    assert {:error, :queue_empty} = Queue.consume(Queue.new(), :steering)
    assert {:error, {:unknown_queue, :other}} = Queue.show(Queue.new(), :other)
  end
end
