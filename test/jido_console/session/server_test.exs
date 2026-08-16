defmodule Jido.Console.Session.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Input, Server, Supervisor}

  setup do
    suffix = System.unique_integer([:positive])
    opts = [name: :"own-#{suffix}", registry: :"own-reg-#{suffix}", sessions: :"own-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)
    {:ok, server} = Server.ensure_started(session.id, registry: opts[:registry], supervisor: opts[:sessions])
    %{server: server, session: session, opts: opts}
  end

  test "the server owns sequence allocation and rejects a second owner", %{
    server: server,
    session: session,
    opts: opts
  } do
    client = Identity.new!(:client, session_id: session.id)
    assert {:ok, snapshot} = Server.attach(server, client)
    assert snapshot["payload"]["sequence"] == 0
    assert {:ok, ^server} = Server.ensure_started(session.id, registry: opts[:registry], supervisor: opts[:sessions])

    first = Server.next_sequence(server)
    second = Server.next_sequence(server)
    assert first == 1
    assert second == 2
    assert Server.state(server).sequence == 0
  end

  test "the server exposes no raw admission bypass for missing, mixed, or foreign identities" do
    refute {:admit_event, 2} in Server.__info__(:functions)
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

    assert {:ok, delivery} = Server.ack(server, client.id, session.id, 0)
    assert delivery.last_acked == 0
    assert delivery.pending == []

    assert {:error, :future_ack} = Server.ack(server, client.id, session.id, 1)
    assert {:error, :recovery_not_required} = Server.recover(server, client.id)
    assert :ok = Server.stop(server)
    refute Process.alive?(server)
  end

  test "stale, repeated, and cross-session results cannot resolve current work", %{server: server, session: session} do
    live = Identity.new!(:request, session_id: session.id, id: "req_live")
    assert {:ok, :done} = Server.admit_result(server, live, :done)
    assert {:error, :repeated_result} = Server.admit_result(server, live, :again)

    other = Identity.new!(:request, session_id: Identity.new!(:session).id, id: "req_other")
    assert {:error, :cross_session_result} = Server.admit_result(server, other, :nope)
  end
end
