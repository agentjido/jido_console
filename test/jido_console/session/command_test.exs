defmodule Jido.Console.Session.CommandTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Command, Queue}

  test "validates every command shape and rejects invalid input" do
    assert %Zoi.Types.Struct{} = Command.schema()
    assert {:error, :invalid_command} = Command.new(:invalid)
    assert {:error, :invalid_command} = Command.new(%{})

    assert {:error, :invalid_command} =
             Command.new(id: "command", thread_id: "thread", type: :cancel)

    assert_raise ArgumentError, fn -> Command.new!(%{}) end

    base = [id: "command", thread_id: "thread"]

    assert {:ok, %Command{}} =
             Command.new(base ++ [type: :submit, queue_item_id: "item", request_id: "request", text: "hello"])

    assert {:ok, %Command{}} = Command.new(base ++ [type: :cancel, request_id: "request"])
    assert {:ok, %Command{}} = Command.new(base ++ [type: :approve, request_id: "request", review_id: "review"])
    assert {:ok, %Command{}} = Command.new(base ++ [type: :deny, request_id: "request", review_id: "review"])
    assert {:ok, %Command{}} = Command.new(base ++ [type: :remove, queue_item_id: "item"])

    assert {:ok, %Command{type: :select_model, text: "ollama:llama3.2"}} =
             Command.new(base ++ [type: :select_model, text: "ollama:llama3.2"])

    assert {:error, :invalid_command} = Command.new(base ++ [type: :select_model, text: "ollama"])

    for type <- [:status, :history, :stop] do
      assert {:ok, %Command{type: ^type}} = Command.new(base ++ [type: type])
    end

    assert {:ok, %Command{type: :history}} =
             Command.new(base ++ [type: :history, payload: %{"limit" => 10, "before_sequence" => 20}])

    assert {:ok, %Command{type: :history}} =
             Command.new(base ++ [type: :history, payload: %{limit: 10, before_sequence: 20}])
  end

  test "rejects unrelated command fields and malformed variant payloads" do
    base = [id: "command", thread_id: "thread"]

    invalid = [
      base ++ [type: :status, request_id: "unexpected"],
      base ++ [type: :stop, payload: %{"future" => true}],
      base ++ [type: :cancel, request_id: "request", text: "unexpected"],
      base ++ [type: :remove, queue_item_id: "item", request_id: "unexpected"],
      base ++ [type: :submit, queue_item_id: "item", request_id: "request", text: "hello", payload: %{"context" => []}],
      base ++ [type: :submit, queue_item_id: "item", request_id: "request", text: "hello", payload: %{"extra" => %{}}],
      base ++ [type: :history, payload: %{"limit" => 0}],
      base ++ [type: :history, payload: %{"limit" => 1_001}],
      base ++ [type: :history, payload: %{"before_sequence" => "10"}],
      base ++ [type: :history, payload: %{"limit" => 10, limit: 10}],
      base ++ [type: :select_model],
      base ++ [type: :select_model, text: "ollama:llama3.2", payload: %{"extra" => true}]
    ]

    for attrs <- invalid do
      assert {:error, :invalid_command} = Command.new(attrs)
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
