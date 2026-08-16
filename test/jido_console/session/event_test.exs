defmodule Jido.Console.Session.EventTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Event, Identity}

  test "classified events carry sequence, classes, origin, trust, and identities" do
    session = Identity.new!(:session)
    request = Identity.new!(:request, session_id: session.id)

    assert {:ok, event} =
             Event.classify(%{
               type: "input_admitted",
               session_id: session.id,
               sequence: 1,
               durability: "process",
               sensitivity: "public",
               origin: %{kind: "client", actor_id: "cli_tui"},
               trust: %{evidence: "admitted", policy: "session-owner"},
               identities: [Identity.to_protocol(request)],
               input_id: request.id,
               client_id: "cli_tui"
             })

    assert event["payload"]["sequence"] == 1
    assert event["payload"]["durability"] == "process"
    assert event["payload"]["sensitivity"] == "public"
    assert event["session_id"] == session.id

    assert [session_identity, request_identity] = event["payload"]["identities"]
    assert session_identity == %{"kind" => "session", "id" => session.id, "session_id" => session.id}
    assert request_identity["id"] == request.id
    refute Event.origin_authority?(event["payload"])
  end

  test "invalid sequence, origin authority, and raw runtime values fail" do
    base = %{
      type: "input_admitted",
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "client", actor_id: "cli_tui"},
      trust: %{evidence: "admitted", policy: "session-owner"},
      session_id: "ses_1",
      identities: [%{"kind" => "request", "id" => "req_1", "session_id" => "ses_1"}]
    }

    assert {:error, {:missing_protocol_fields, "event", "input_admitted", ["sequence"]}} =
             Event.classify(base)

    assert {:error, :origin_cannot_grant_authority} =
             Event.classify(
               Map.merge(base, %{sequence: 1, origin: %{kind: "client", actor_id: "cli_tui", authority: true}})
             )

    assert {:error, :raw_runtime_forbidden} = Event.classify(Map.put(base, :sequence, self()))
  end

  test "missing, nil, and empty session identities fail" do
    base = event_attrs("ses_1")

    assert {:error, :invalid_event_session_id} = Event.classify(Map.delete(base, :session_id))
    assert {:error, :invalid_event_session_id} = Event.classify(Map.put(base, :session_id, nil))
    assert {:error, :invalid_event_session_id} = Event.classify(Map.put(base, :session_id, ""))
  end

  test "mixed and foreign embedded identities fail" do
    base = event_attrs("ses_1")

    mixed = [
      %{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"},
      %{"kind" => "request", "id" => "req_1", "session_id" => "ses_2"}
    ]

    foreign = [%{"kind" => "session", "id" => "ses_2", "session_id" => "ses_1"}]

    assert {:error, :event_identity_mismatch} = Event.classify(%{base | identities: mixed})
    assert {:error, :event_identity_mismatch} = Event.classify(%{base | identities: foreign})
  end

  test "embedded identities require a nonempty session ID" do
    base = event_attrs("ses_1")
    missing = [%{"kind" => "request", "id" => "req_1"}]
    nil_id = [%{"kind" => "request", "id" => "req_1", "session_id" => nil}]
    empty = [%{"kind" => "request", "id" => "req_1", "session_id" => ""}]

    assert {:error, :invalid_event_identity} = Event.classify(%{base | identities: missing})
    assert {:error, :invalid_event_identity} = Event.classify(%{base | identities: nil_id})
    assert {:error, :invalid_event_identity} = Event.classify(%{base | identities: empty})
  end

  test "validates classified envelopes without constructing missing identities" do
    session = Identity.new!(:session)

    {:ok, event} =
      Event.classify(%{
        type: "run_started",
        session_id: session.id,
        sequence: 1,
        durability: "process",
        sensitivity: "public",
        origin: %{kind: "session", actor_id: session.id},
        trust: %{evidence: "test", policy: "session-owner"},
        identities: [Identity.to_protocol(session)]
      })

    assert {:ok, ^event} = Event.validate(event)

    missing = update_in(event, ["payload"], &Map.delete(&1, "identities"))
    empty = put_in(event, ["payload", "identities"], [])

    assert {:error, {:missing_protocol_fields, "event", "run_started", ["identities"]}} =
             Event.validate(missing)

    assert {:error, :event_session_identity_missing} = Event.validate(empty)
  end

  test "rejects invalid event classes, trust, origin, identities, and shapes" do
    assert {:error, :invalid_event} = Event.classify(:invalid)
    assert {:error, :invalid_event} = Event.validate(:invalid)
    assert Event.origin_authority?(%{"origin" => %{"kind" => "host", "actor_id" => "user"}})
    refute Event.origin_authority?(%{})

    base = event_attrs("ses_1")

    cases = [
      {%{base | sequence: -1}, :invalid_event_sequence},
      {%{base | durability: "durable"}, {:invalid_event_class, "durability"}},
      {%{base | sensitivity: "unknown"}, {:invalid_event_class, "sensitivity"}},
      {%{base | origin: %{"kind" => "client"}}, :invalid_event_origin},
      {%{base | trust: %{"evidence" => "test"}}, :invalid_event_trust},
      {%{base | identities: :invalid}, :invalid_event_identity},
      {%{
         base
         | identities: [
             %{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"},
             %{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"}
           ]
       }, :event_identity_mismatch}
    ]

    for {attrs, expected} <- cases do
      assert {:error, ^expected} = Event.classify(attrs)
    end

    assert {:error, :raw_runtime_forbidden} =
             Event.classify(%{base | identities: [%{"kind" => "request", "id" => "request", "session_id" => self()}]})
  end

  defp event_attrs(session_id) do
    %{
      type: "input_admitted",
      session_id: session_id,
      sequence: 1,
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "client", actor_id: "cli_tui"},
      trust: %{evidence: "admitted", policy: "session-owner"},
      identities: []
    }
  end

  test "classification does not keep live sequence state" do
    source = File.read!("lib/jido_console/session/event.ex")
    refute source =~ ":ets"
    refute source =~ "Agent."
    refute source =~ "Process.put"
    refute source =~ "next_sequence"
    refute source =~ "@sequence"
  end
end
