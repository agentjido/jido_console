defmodule Jido.Console.Session.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Event, Identity, Input, Server, Supervisor}

  setup do
    suffix = System.unique_integer([:positive])
    opts = [name: :"own-#{suffix}", registry: :"own-reg-#{suffix}", sessions: :"own-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)
    {:ok, server} = Server.ensure_started(session.id, registry: opts[:registry], supervisor: opts[:sessions])
    %{server: server, session: session, opts: opts}
  end

  test "the server owns event order and rejects a second owner", %{server: server, session: session, opts: opts} do
    client = Identity.new!(:client, session_id: session.id)
    assert {:ok, snapshot} = Server.attach(server, client)
    assert snapshot["payload"]["sequence"] == 0
    assert {:ok, ^server} = Server.ensure_started(session.id, registry: opts[:registry], supervisor: opts[:sessions])

    first = Server.next_sequence(server)
    second = Server.next_sequence(server)
    assert first == 1
    assert second == 2
    {:ok, event} = classify(session, "run_started", first)
    assert {:ok, state} = Server.admit_event(server, event)
    assert state.sequence == 1
    assert_receive {:session_updated, session_id, _snapshot}
    assert session_id == session.id
  end

  test "clients can detach and reattach while the session stays alive", %{server: server, session: session} do
    client = Identity.new!(:client, session_id: session.id)
    assert {:ok, _} = Server.attach(server, client)
    assert :ok = Server.detach(server, client)
    assert Process.alive?(server)
    assert {:ok, _} = Server.attach(server, client)
  end

  test "the server records admitted input and bounds client delivery", %{server: server, session: session} do
    client = Identity.new!(:client, session_id: session.id)
    assert {:ok, _} = Server.attach(server, client)
    {:ok, input} = Input.admit("steer this", session_id: session.id)
    assert {:ok, ^input} = Server.admit_input(server, input)

    other = Identity.new!(:session)
    {:ok, foreign} = Input.admit("nope", session_id: other.id)
    assert {:error, :cross_session_result} = Server.admit_input(server, foreign)

    sequence = Server.next_sequence(server)
    {:ok, event} = classify(session, "run_started", sequence)
    assert {:ok, _} = Server.admit_event(server, event)
    assert_receive {:session_updated, session_id, snapshot}
    assert session_id == session.id
    assert snapshot["coalesce"] == true

    sequence = snapshot["payload"]["sequence"]
    assert {:ok, delivery} = Server.ack(server, client.id, session.id, sequence)
    assert delivery.last_acked == sequence
    assert delivery.pending == []
  end

  test "stale, repeated, and cross-session results cannot resolve current work", %{server: server, session: session} do
    live = Identity.new!(:request, session_id: session.id, id: "req_live")
    assert {:ok, :done} = Server.admit_result(server, live, :done)
    assert {:error, :repeated_result} = Server.admit_result(server, live, :again)

    other = Identity.new!(:request, session_id: Identity.new!(:session).id, id: "req_other")
    assert {:error, :cross_session_result} = Server.admit_result(server, other, :nope)
  end

  defp classify(session, type, sequence) do
    Event.classify(%{
      type: type,
      id: "plt_event_#{sequence}",
      session_id: session.id,
      sequence: sequence,
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "session", actor_id: session.id},
      trust: %{evidence: "owner", policy: "session-owner"},
      identities: [Identity.to_protocol(session)]
    })
  end
end
