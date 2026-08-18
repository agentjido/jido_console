defmodule Jido.Console.Session.DeliveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Delivery, Event, Protocol, Reducer, State}

  @identity %{
    session_id: "ses_1",
    client_id: "cli_1",
    attachment_id: "att_1",
    generation: 1,
    owner_instance_id: "owner-1"
  }

  test "the first update makes one readiness advisory and later updates do not" do
    delivery = delivery()
    first = event(1)
    second = event(2)

    assert {:ok, delivery, true} = Delivery.offer(delivery, first)
    assert {:ok, delivery, false} = Delivery.offer(delivery, second)
    assert delivery.queue == [first, second]
    assert Delivery.measurements(delivery).advisory_count == 1
    assert :erlang.external_size(Delivery.advisory(delivery)) <= Delivery.maximums().advisory_bytes
  end

  test "one bounded batch must be acknowledged before another pull" do
    delivery = delivery(limits: %{batch_count: 2})
    {:ok, delivery, true} = Delivery.offer(delivery, event(1))
    {:ok, delivery, false} = Delivery.offer(delivery, event(2))
    {:ok, delivery, false} = Delivery.offer(delivery, event(3))

    assert {:ok, delivery, batch} = Delivery.pull(delivery, @identity)
    assert batch["family"] == "delivery"
    assert batch["type"] == "output_batch"
    assert length(batch["payload"]["events"]) == 2
    assert batch["payload"]["first_sequence"] == 1
    assert batch["payload"]["through_sequence"] == 2
    token = batch["payload"]["acknowledgement_token"]

    assert {:error, :ack_required, ^delivery} = Delivery.pull(delivery, @identity)
    assert {:error, :invalid_acknowledgement, ^delivery} = Delivery.ack(delivery, @identity, "made-up")

    assert {:ok, acknowledged, receipt, true} = Delivery.ack(delivery, @identity, token)
    assert receipt["through_sequence"] == 2
    assert acknowledged.last_acked == 2
    assert length(acknowledged.queue) == 1

    assert {:ok, ^acknowledged, ^receipt, false} = Delivery.ack(acknowledged, @identity, token)
  end

  test "tokens and pulls bind all three identities" do
    {:ok, delivery, _advisory?} = Delivery.offer(delivery(), event(1))

    for field <- [:session_id, :client_id, :attachment_id] do
      wrong = Map.put(@identity, field, "wrong")
      assert {:error, :delivery_identity_mismatch, ^delivery} = Delivery.pull(delivery, wrong)
    end

    assert {:ok, delivery, batch} = Delivery.pull(delivery, @identity)
    token = batch["payload"]["acknowledgement_token"]
    wrong_attachment = %{@identity | attachment_id: "old_attachment"}

    assert {:error, :delivery_identity_mismatch, ^delivery} =
             Delivery.ack(delivery, wrong_attachment, token)
  end

  test "queue count, byte, and event limits create one bounded delivery gap" do
    count_limited = delivery(limits: %{queue_count: 1})
    {:ok, count_limited, _} = Delivery.offer(count_limited, event(1))

    assert {:gap, gapped, gap, false} = Delivery.offer(count_limited, event(2))
    assert gapped.status == :gapped
    assert gapped.queue == []
    assert gapped.queued_bytes == 0
    assert gap["family"] == "delivery"
    assert gap["type"] == "gap"
    assert gap["payload"]["reason"] == "queue_count_overflow"
    refute Map.has_key?(gap["payload"], "sequence")

    assert {:gap, ^gapped, ^gap, false} = Delivery.offer(gapped, event(3))

    oversized =
      delivery(limits: %{batch_bytes: 2_000, queue_bytes: 2_000})

    assert {:gap, oversized, gap, true} =
             Delivery.offer(oversized, event(1, String.duplicate("x", 4_000)))

    assert oversized.status == :gapped
    assert gap["payload"]["reason"] == "update_too_large"
  end

  test "a caller coalesce flag cannot replace a distinct canonical event" do
    first = put_in(event(1), ["payload", "coalesce"], true)
    second = put_in(event(2), ["payload", "coalesce"], true)
    delivery = delivery(limits: %{queue_count: 1})

    {:ok, delivery, _} = Delivery.offer(delivery, first)
    assert {:gap, gapped, _gap, _advisory?} = Delivery.offer(delivery, second)
    assert gapped.status == :gapped
  end

  test "only the exact same event identity and sequence is suppressed" do
    event = event(1)
    {:ok, delivery, _} = Delivery.offer(delivery(), event)
    assert {:duplicate, ^delivery} = Delivery.offer(delivery, event)

    conflict = put_in(event, ["payload", "text"], "different")
    assert {:duplicate, ^delivery} = Delivery.offer(delivery, conflict)
  end

  test "an exact timer token gaps one batch and a stale token does nothing" do
    {:ok, delivery, _} = Delivery.offer(delivery(), event(1))
    {:ok, delivery, _batch} = Delivery.pull(delivery, @identity)

    assert {:ok, ^delivery} =
             Delivery.timeout(delivery, "att_1", "stale_timer", 1)

    assert {:gap, gapped, gap, true} =
             Delivery.timeout(delivery, "att_1", delivery.inflight.timer_token, 1)

    assert gapped.status == :gapped
    assert gap["payload"]["reason"] == "acknowledgement_timeout"
    assert {:error, :delivery_gapped, ^gapped} = Delivery.ack(gapped, @identity, "anything")
  end

  test "ten thousand updates keep stopped-receiver payload state bounded" do
    delivery = delivery()
    receiver = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    delivery =
      Enum.reduce(1..10_000, delivery, fn sequence, state ->
        case Delivery.offer(state, event(sequence)) do
          {:ok, next, advisory?} ->
            if advisory?, do: send(receiver, Delivery.advisory(next))
            next

          {:duplicate, next} ->
            next

          {:gap, next, _gap, advisory?} ->
            if advisory?, do: send(receiver, Delivery.advisory(next))
            next
        end
      end)

    measurements = Delivery.measurements(delivery)
    assert {:message_queue_len, 1} = Process.info(receiver, :message_queue_len)
    assert {:messages, [advisory]} = Process.info(receiver, :messages)
    assert :erlang.external_size(advisory) <= Delivery.maximums().advisory_bytes
    assert measurements.status == :gapped
    assert measurements.queue_count == 0
    assert measurements.queued_bytes == 0
    assert measurements.inflight_bytes == 0
    assert measurements.advisory_count == 1
  end

  test "the deprecated canonical gap remains readable but cannot enter new history" do
    {:ok, schema} = Protocol.schema()

    attrs = %{
      "id" => "old_gap",
      "session_id" => "ses_1",
      "sequence" => 1,
      "durability" => "process",
      "sensitivity" => "public",
      "origin" => %{"kind" => "system", "actor_id" => "legacy"},
      "trust" => %{"evidence" => "legacy", "policy" => "legacy"},
      "identities" => [%{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"}],
      "client_id" => "cli_1",
      "last_acknowledged" => 0,
      "current_sequence" => 1
    }

    assert {:ok, old_gap} = Protocol.envelope(schema, "event", "delivery_gap", attrs)
    assert {:ok, _readable} = Event.validate(old_gap)
    assert {:error, :deprecated_event_emission} = Event.classify(Map.put(attrs, "type", "delivery_gap"))
    assert {:error, :deprecated_event_emission} = Reducer.apply_event(State.new("ses_1"), old_gap)
  end

  defp delivery(opts \\ []) do
    Delivery.new(
      Keyword.merge(
        [
          session_id: "ses_1",
          client_id: "cli_1",
          attachment_id: "att_1",
          generation: 1,
          owner_instance_id: "owner-1",
          token_secret: String.duplicate("s", 32)
        ],
        opts
      )
    )
  end

  defp event(sequence, text \\ "delta") do
    attrs = %{
      type: "model_delta",
      id: "event_#{sequence}",
      session_id: "ses_1",
      sequence: sequence,
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "session", actor_id: "ses_1"},
      trust: %{evidence: "test", policy: "test"},
      identities: [%{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"}],
      run_id: "run_1",
      text: text
    }

    {:ok, event} = Event.classify(attrs)
    event
  end
end
