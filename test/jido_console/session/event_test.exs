defmodule Jido.Console.Session.EventTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Event, Identity}

  test "classified events carry sequence, classes, origin, trust, and identities" do
    session = Identity.new!(:session)
    request = Identity.new!(:request, session_id: session.id)

    assert {:ok, event} =
             Event.classify(%{
               type: "input_admitted",
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
    refute Event.origin_authority?(event["payload"])
  end

  test "invalid sequence, origin authority, and raw runtime values fail" do
    base = %{
      type: "input_admitted",
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "client", actor_id: "cli_tui"},
      trust: %{evidence: "admitted", policy: "session-owner"},
      identities: [%{"kind" => "request", "id" => "req_1", "session_id" => "ses_1"}]
    }

    assert {:error, :invalid_event_sequence} = Event.classify(base)

    assert {:error, :origin_cannot_grant_authority} =
             Event.classify(
               Map.merge(base, %{sequence: 1, origin: %{kind: "client", actor_id: "cli_tui", authority: true}})
             )

    assert {:error, :raw_runtime_forbidden} = Event.classify(Map.put(base, :sequence, self()))
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
