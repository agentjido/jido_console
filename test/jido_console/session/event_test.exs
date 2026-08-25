defmodule Jido.Console.Session.EventTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Event

  test "builds and validates one portable product event" do
    event =
      Event.new!(
        id: "command-1:prompt_queued",
        type: "prompt_queued",
        session_id: "thread-1",
        queue_item_id: "command-1",
        request_id: "request-1",
        payload: %{"input" => "hello"}
      )

    assert {:ok, ^event} = Event.validate(event)
    assert event.sequence == nil
    assert event.committed_at_ms == nil
    assert Event.commit(event, 1, 10).sequence == 1
    refute inspect(event) =~ "#PID"
  end

  test "rejects unknown types, unsupported versions, and incomplete identities" do
    attrs = %{
      id: "event-1",
      type: "prompt_queued",
      session_id: "thread-1",
      queue_item_id: "item-1",
      request_id: "request-1"
    }

    assert {:error, :invalid_thread_event} = Event.new(%{attrs | type: "lease_claimed"})
    assert {:error, {:unsupported_thread_event_schema, 2}} = Event.new(Map.put(attrs, :schema_version, 2))
    assert {:error, :invalid_thread_event} = Event.new(Map.delete(attrs, :request_id))
    assert {:error, :invalid_thread_event} = Event.new(Map.put(attrs, :payload, %{input: "hello"}))
    assert {:error, :invalid_thread_event} = Event.new(Map.put(attrs, :payload, %{"input" => self()}))
    assert {:error, :invalid_thread_event} = Event.new(Map.put(attrs, :payload, []))
  end

  test "classifies start and closing outcomes" do
    assert Event.started?("prompt_started")
    refute Event.started?("prompt_queued")

    for type <- ~w(prompt_removed prompt_succeeded prompt_failed prompt_cancelled prompt_interrupted) do
      assert Event.closing?(type)
    end

    refute Event.closing?("review_presented")
  end

  test "projects values to JSON data without live runtime terms" do
    assert Event.json(%{status: :ok, nested: {:left, 2}}) == %{
             "status" => "ok",
             "nested" => ["left", 2]
           }
  end

  test "exposes its schema and normalizes all supported string keys" do
    assert Event.schema_version() == 1
    assert "prompt_queued" in Event.types()
    assert %Zoi.Types.Struct{} = Event.schema()

    attrs = %{
      "id" => "event-1",
      "type" => "prompt_queued",
      "session_id" => "thread-1",
      "queue_item_id" => "item-1",
      "request_id" => "request-1",
      "schema_version" => 1,
      "jidoka_revision" => 2,
      "payload" => %{"input" => "hello"},
      "sequence" => 3,
      "committed_at_ms" => 4
    }

    assert {:ok, %Event{} = event} = Event.new(attrs)
    assert {:ok, %Event{}} = Event.validate(attrs)
    assert {:error, :invalid_thread_event} = Event.new(Map.put(attrs, "future_field", "ignored"))
    assert event.sequence == 3
    assert event.committed_at_ms == 4
    assert {:error, :invalid_thread_event} = Event.new(:invalid)
    assert {:error, :invalid_thread_event} = Event.validate(:invalid)
    assert_raise ArgumentError, fn -> Event.new!(%{}) end
  end

  test "projects event identity, views, classifications, and arbitrary JSON values" do
    state = %{thread_id: "thread-1"}
    item = %{id: "item-1", request_id: "request-1"}
    event = Event.for_item(state, item, "prompt_started", %{"answer" => "ok"}, 7) |> Event.commit(2, 10)

    assert Event.started?(event)
    assert Event.closing?(%{event | type: "prompt_failed"})
    refute Event.closing?(:unknown)
    assert Event.identity(event).id == "thread-1:item-1:prompt_started"

    assert Event.to_view(event) == %{
             "committed_at_ms" => 10,
             "id" => "thread-1:item-1:prompt_started",
             "jidoka_revision" => 7,
             "payload" => %{"answer" => "ok"},
             "queue_item_id" => "item-1",
             "request_id" => "request-1",
             "sequence" => 2,
             "type" => "prompt_started"
           }

    assert Event.json([nil, true, 1, 1.5, "text", :atom]) == [nil, true, 1, 1.5, "text", "atom"]
    assert Event.json(event)["id"] == "thread-1:item-1:prompt_started"
    assert Event.json(%{{:key, 1} => self()}) |> Map.has_key?("{:key, 1}")
  end

  test "builds globally unique item IDs and stable review IDs" do
    item = %{id: "shared-item", request_id: "shared-request"}
    first = Event.for_item(%{thread_id: "thread-1"}, item, "prompt_queued", %{})
    second = Event.for_item(%{thread_id: "thread-2"}, item, "prompt_queued", %{})

    refute first.id == second.id
    assert first.id == "thread-1:shared-item:prompt_queued"

    review = Event.for_item(%{thread_id: "thread-1"}, item, "review_presented", %{}, 1, "review-1")
    retry = Event.for_item(%{thread_id: "thread-1"}, item, "review_presented", %{}, 1, "review-1")
    next_review = Event.for_item(%{thread_id: "thread-1"}, item, "review_presented", %{}, 2, "review-2")

    assert review.id == retry.id
    refute review.id == next_review.id
  end
end
