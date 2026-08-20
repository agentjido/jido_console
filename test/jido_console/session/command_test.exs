defmodule Jido.Console.Session.CommandTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Command, Queue}

  test "validates every command shape and rejects invalid input" do
    assert %Zoi.Types.Struct{} = Command.schema()
    assert {:error, :invalid_command} = Command.new(:invalid)
    assert {:error, :invalid_command} = Command.new(%{})
    assert_raise ArgumentError, fn -> Command.new!(%{}) end

    base = [id: "command", thread_id: "thread"]

    assert {:ok, %Command{}} =
             Command.new(base ++ [type: :submit, queue_item_id: "item", request_id: "request", text: "hello"])

    assert {:ok, %Command{}} = Command.new(base ++ [type: :cancel, request_id: "request"])
    assert {:ok, %Command{}} = Command.new(base ++ [type: :approve, request_id: "request", review_id: "review"])
    assert {:ok, %Command{}} = Command.new(base ++ [type: :deny, request_id: "request", review_id: "review"])
    assert {:ok, %Command{}} = Command.new(base ++ [type: :remove, queue_item_id: "item"])

    for type <- [:status, :history, :stop] do
      assert {:ok, %Command{type: ^type}} = Command.new(base ++ [type: type])
    end
  end

  test "builds queue items and stable acceptance data" do
    command =
      Command.new!(
        id: "command",
        type: :submit,
        thread_id: "thread",
        queue_item_id: "item",
        request_id: "request",
        text: "hello",
        payload: %{context: %{mode: :test}}
      )

    digest = Command.digest(command)
    item = Command.item(command, digest)
    assert item.context == %{mode: :test}
    assert Command.from_item(item, "thread").payload == %{"context" => %{mode: :test}}

    {:ok, queue} = Queue.new(2) |> Queue.push(%{item | id: "queued"})
    active_state = %{active: item, queue: queue, thread_id: "thread", status: :running}
    queued_state = %{active: nil, queue: queue, thread_id: "thread", status: :idle}

    assert Command.find_item(active_state, "item") == item
    assert Command.find_item(queued_state, "queued").id == "queued"
    assert Command.find_item(queued_state, "missing") == nil
    assert Command.acceptance(item, true, active_state).status == :running
    assert Command.acceptance(item, false, queued_state).status == :queued
  end
end
