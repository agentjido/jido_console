defmodule Jido.Console.Session.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Runtime.Result, as: RuntimeResult
  alias Jido.Console.Session.{History, Identity, Server, Supervisor}

  defmodule FakeRuntime do
    def start_session(agent, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_start, agent, opts})

      case Keyword.get(opts, :start_result, :ok) do
        :ok -> {:ok, %{test_pid: opts[:test_pid], value: Keyword.get(opts, :value)}}
        :error -> {:error, :runtime_start_failed}
        :invalid -> :invalid
        :raise -> raise "runtime start raised"
        :throw -> throw(:runtime_start_threw)
      end
    end

    def close_session(session) do
      send(session.test_pid, {:runtime_closed, session.value})
      :ok
    end
  end

  defmodule ResourceCloser do
    def close(resource, test_pid) do
      send(test_pid, {:resource_closed, resource})
      :ok
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    opts = [name: :"own-#{suffix}", registry: :"own-reg-#{suffix}", sessions: :"own-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)
    {:ok, server} = Server.ensure_started(session.id, registry: opts[:registry], supervisor: opts[:sessions])
    {:ok, fence} = Server.generation(server)

    session =
      Identity.new!(:session,
        id: session.id,
        generation: fence.generation,
        owner_instance_id: fence.owner_instance_id
      )

    %{server: server, session: session, opts: opts}
  end

  test "the server owns sequence allocation and rejects a second owner", %{
    server: server,
    session: session,
    opts: opts
  } do
    client = identity(:client, session)
    assert {:ok, []} = attach_client(server, client)
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
    client = identity(:client, session)
    assert {:ok, _} = attach_client(server, client)
    assert :ok = Server.detach(server, client)
    assert Process.alive?(server)
    assert {:ok, _} = attach_client(server, client)
  end

  test "a restarted owner rejects old clients, requests, and runtime messages", %{
    server: server,
    session: session,
    opts: opts
  } do
    old_client = identity(:client, session)

    assert {:ok, %{attachment: old_attachment}} = Server.attach(server, old_client)

    assert {:ok, old_request} =
             Server.start_operation(server, old_client.id,
               start: fn _owner -> {:ok, %{request_id: "old-request"}} end,
               await: fn _request -> :old_complete end
             )

    assert :old_complete = Server.await_request(server, old_request, 1_000)

    old_handle_identity = %{
      session_id: session.id,
      client_id: old_client.id,
      attachment_id: old_attachment.id,
      generation: session.generation,
      owner_instance_id: session.owner_instance_id
    }

    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}

    assert {:ok, replacement} =
             Server.ensure_started(session.id,
               registry: opts[:registry],
               supervisor: opts[:sessions]
             )

    assert {:ok, next_fence} = Server.generation(replacement)
    assert next_fence.generation == session.generation + 1
    refute next_fence.owner_instance_id == session.owner_instance_id

    assert {:error, :stale_generation} = Server.attach(replacement, old_client)
    assert {:error, :stale_generation} = Server.detach(replacement, old_client)
    assert {:error, :stale_generation} = Server.await_request(replacement, old_request, 100)

    assert {:error, :stale_generation} =
             Server.client_operation(replacement, old_handle_identity, :status)

    before = Server.state(replacement)

    send(replacement, {:jidoka_turn_event, :old_runtime_event})
    Process.sleep(10)
    assert Server.state(replacement) == before
  end

  test "attachments receive direct events and can read the complete history", %{
    server: server,
    session: session
  } do
    client = identity(:client, session)

    assert {:ok, %{attachment: attachment, events: []}} = Server.attach(server, client)
    test_pid = self()

    spec = [
      start: fn _owner -> {:ok, %{request_id: "bounded-request"}} end,
      await: fn _request ->
        send(test_pid, {:bounded_await, self()})

        receive do
          :finish_bounded -> :done
        end
      end
    ]

    assert {:ok, request} = Server.start_operation(server, client.id, spec)
    assert_receive {:bounded_await, worker}
    assert_receive {:jido_console_session, attachment_id, {:event, started}}
    assert attachment_id == attachment.id
    assert started["type"] == "run_started"

    assert {:ok, durable_started} = History.rebuild(session.id)
    assert durable_started.state.sequence == 1
    assert Enum.map(durable_started.state.history, & &1["type"]) == ["run_started"]

    assert {:ok, [^started]} = client_call(server, session, client, attachment.id, :events)

    assert {:error, :attachment_identity_mismatch} =
             client_call(server, session, client, "old_attachment", :events)

    send(worker, :finish_bounded)
    assert :done = Server.await_request(server, request, 1_000)
    assert_receive {:jido_console_session, ^attachment_id, {:event, completed}}
    assert completed["type"] == "run_completed"
    assert {:ok, [^started, ^completed]} = client_call(server, session, client, attachment.id, :events)

    assert {:ok, durable_terminal} = History.rebuild(session.id)
    assert durable_terminal.state.sequence == 2
    assert durable_terminal.events == 2
  end

  test "reattach returns full history and receives later events directly", %{
    server: server,
    session: session
  } do
    client = identity(:client, session)

    assert {:ok, %{attachment: first_attachment, events: []}} = Server.attach(server, client)

    first_spec = [
      start: fn _owner -> {:ok, %{request_id: "first-request"}} end,
      await: fn _request -> :first_done end
    ]

    assert {:ok, first_request} = Server.start_operation(server, client.id, first_spec)
    assert :first_done = Server.await_request(server, first_request, 1_000)
    assert_receive {:jido_console_session, first_id, {:event, _started}}
    assert first_id == first_attachment.id
    assert_receive {:jido_console_session, ^first_id, {:event, _completed}}

    assert {:ok, %{attachment: second_attachment, events: history}} = Server.attach(server, client)
    assert Enum.map(history, & &1["type"]) == ["run_started", "run_completed"]

    second_spec = [
      start: fn _owner -> {:ok, %{request_id: "second-request"}} end,
      await: fn _request -> :second_done end
    ]

    assert {:ok, second_request} = Server.start_operation(server, client.id, second_spec)
    assert :second_done = Server.await_request(server, second_request, 1_000)
    assert_receive {:jido_console_session, second_id, {:event, later_started}}
    assert second_id == second_attachment.id
    assert_receive {:jido_console_session, ^second_id, {:event, later_completed}}
    assert [3, 4] == Enum.map([later_started, later_completed], & &1["payload"]["sequence"])
  end

  test "stale, repeated, and cross-session results cannot resolve current work", %{server: server, session: session} do
    live = identity(:request, session, id: "req_live")
    assert {:ok, :done} = Server.admit_result(server, live, :done)
    assert {:error, :repeated_result} = Server.admit_result(server, live, :again)

    other = Identity.new!(:request, session_id: Identity.new!(:session).id, id: "req_other")
    assert {:error, :cross_session_result} = Server.admit_result(server, other, :nope)
  end

  test "runtime configuration validates ownership and always closes replaced resources", %{
    server: server,
    session: session
  } do
    client = identity(:client, session)
    foreign = Identity.new!(:client, session_id: Identity.new!(:session).id)

    assert {:error, :cross_session_result} = attach_client(server, foreign)
    assert {:error, :not_attached} = Server.detach(server, client)
    assert {:error, :not_attached} = Server.runtime_info(server, client.id)
    assert {:error, :not_attached} = Server.configure_runtime(server, client.id, FakeRuntime, :agent, [])

    assert {:ok, _events} = attach_client(server, client)
    assert {:ok, %{configured?: false, active_request: nil}} = Server.runtime_info(server, client.id)
    assert {:error, :invalid_runtime} = Server.configure_runtime(server, client.id, "runtime", :agent, [])

    closer = {ResourceCloser, :close, [self()]}

    assert :ok =
             Server.configure_runtime(server, client.id, FakeRuntime, :first,
               test_pid: self(),
               value: :first,
               client_setup: %{profile: "restricted"},
               owned_resource: :first_resource,
               resource_closer: closer
             )

    assert_receive {:runtime_start, :first, first_options}
    refute Keyword.has_key?(first_options, :owned_resource)
    assert {:ok, info} = Server.runtime_info(server, client.id)
    assert info.configured?
    assert info.active_request == nil
    assert info.client_setup == %{profile: "restricted"}

    assert :ok =
             Server.configure_runtime(server, client.id, FakeRuntime, :second,
               test_pid: self(),
               value: :second
             )

    assert_receive {:runtime_closed, :first}
    assert_receive {:resource_closed, :first_resource}

    for start_result <- [:error, :invalid, :raise, :throw] do
      resource = {:failed, start_result}

      assert {:error, _reason} =
               Server.configure_runtime(server, client.id, FakeRuntime, :failed,
                 test_pid: self(),
                 start_result: start_result,
                 owned_resource: resource,
                 resource_closer: closer
               )

      assert_receive {:resource_closed, ^resource}
    end

    assert :ok = Server.stop(server)
    assert_receive {:runtime_closed, :second}
    assert :ok = Server.stop(server)
  end

  test "caller operations have deterministic start, await, cancellation, and error paths", %{
    server: server,
    session: session
  } do
    client = identity(:client, session)
    assert {:ok, _events} = attach_client(server, client)
    assert {:error, :idempotency_key_required} = Server.start_turn(server, client.id, "prompt", [])

    assert {:error, :runtime_not_configured} =
             Server.start_turn(server, client.id, "prompt", idempotency_key: "server-turn")

    assert {:error, :invalid_session_operation} = Server.start_operation(server, client.id, :invalid)
    assert {:error, :invalid_session_operation} = Server.start_operation(server, client.id, start: fn _ -> :ok end)

    for {start, expected} <- [
          {fn _owner -> {:error, :start_failed} end, :start_failed},
          {fn _owner -> :invalid end, {:invalid_runtime_request, :invalid}},
          {fn _owner -> raise "start raised" end, %RuntimeError{message: "start raised"}},
          {fn _owner -> throw(:start_threw) end, {:throw, :start_threw}}
        ] do
      assert {:error, ^expected} =
               Server.start_operation(server, client.id,
                 start: start,
                 await: fn _request -> :unused end
               )
    end

    test_pid = self()

    spec = [
      start: fn owner ->
        send(test_pid, {:operation_started, owner})
        {:ok, %{sequence: %{request_id: "raw-request"}}}
      end,
      await: fn raw_request ->
        send(test_pid, {:operation_awaiting, self(), raw_request})

        receive do
          {:finish_operation, result} -> result
        end
      end,
      cancel: fn raw_request, opts ->
        send(test_pid, {:operation_cancelled, raw_request, opts})
        {:ok, :cancelled}
      end,
      run_id: "run-fixed",
      prompt: "prompt"
    ]

    assert {:ok, request} = Server.start_operation(server, client.id, spec)
    assert request.request_id == "raw-request"
    assert request.run_id == "run-fixed"
    assert_receive {:operation_started, relay}
    assert is_pid(relay)
    refute relay == server
    assert_receive {:operation_awaiting, await_worker, raw_request}
    assert {:ok, %{active_request: ^request}} = Server.runtime_info(server, client.id)
    assert {:error, :session_busy} = Server.start_operation(server, client.id, spec)
    assert {:error, :session_busy} = Server.configure_runtime(server, client.id, FakeRuntime, :agent, [])

    foreign = %{request | session_id: Identity.new!(:session).id}
    stale = %{request | id: "stale"}
    assert {:error, :cross_session_result} = Server.await_request(server, foreign, 100)
    assert {:error, :stale_request} = Server.await_request(server, stale, 100)
    assert {:error, :session_await_timeout} = Server.await_request(server, request, 0)
    assert {:error, :invalid_review_decision} = Server.respond_review(server, client.id, :later, request, nil, [])
    assert {:error, :review_not_pending} = Server.respond_review(server, client.id, :approve, request, nil, [])
    assert {:error, :cross_session_result} = Server.respond_review(server, client.id, :approve, foreign, nil, [])

    assert {:ok, :requested} = Server.cancel_request(server, client.id, request, reason: :user)
    assert_receive {:operation_cancelled, ^raw_request, [reason: :user]}
    assert {:ok, :cancelled} = Server.cancel_request_wait(server, client.id, request, [], 1_000)
    assert_receive {:operation_cancelled, ^raw_request, []}

    waiter = Task.async(fn -> Server.await_request(server, request, 1_000) end)
    send(await_worker, {:finish_operation, {:error, :operation_failed}})
    assert {:error, :operation_failed} = Task.await(waiter)
    assert {:error, :operation_failed} = Server.await_request(server, request, 100)
    assert {:error, :request_already_finished} = Server.cancel_request(server, client.id, request, [])

    assert {:error, :request_already_finished} =
             Server.respond_review(server, client.id, :approve, request, nil, [])

    assert {:error, :not_attached} = Server.cancel_request(server, "missing", request, [])

    assert :ok = Server.detach_async(server, client)
    assert %{} = Server.state(server)
    assert {:error, :not_attached} = Server.runtime_info(server, client.id)
  end

  test "review and cancellation waiters finish through monitored tasks", %{
    server: server,
    session: session
  } do
    client = identity(:client, session)
    assert {:ok, _events} = attach_client(server, client)
    test_pid = self()

    pending_spec = [
      start: fn _owner -> {:ok, %{request_id: "pending-request"}} end,
      await: fn raw_request ->
        RuntimeResult.pending_review("pending-request", :runtime_session, raw_request, [%{id: "review"}])
      end,
      respond_review: fn decision, pending, review, opts, owner ->
        send(test_pid, {:review_response, decision, pending, review, opts, owner})
        :review_complete
      end
    ]

    assert {:ok, request} = Server.start_operation(server, client.id, pending_spec)
    assert %RuntimeResult{} = Server.await_request(server, request, 1_000)
    assert {:ok, %{active_request: ^request}} = Server.runtime_info(server, client.id)

    assert {:ok, :requested} =
             Server.respond_review(server, client.id, :approve, request, %{id: "review"}, source: :test)

    assert_receive {:review_response, :approve, %RuntimeResult{}, %{id: "review"}, [source: :test], relay}
    assert is_pid(relay)
    refute relay == server
    assert :review_complete = Server.await_request(server, request, 1_000)

    [requested, decided] =
      server
      |> Server.state()
      |> Map.fetch!(:history)
      |> Enum.filter(&(&1["type"] in ["permission_requested", "permission_decided"]))

    assert requested["payload"]["approval_id"] == "review"
    assert decided["payload"]["approval_id"] == requested["payload"]["approval_id"]

    blocking_spec = [
      start: fn _owner -> {:ok, %{request_id: "cancel-timeout"}} end,
      await: fn _request ->
        send(test_pid, {:await_waiting, self()})

        receive do
          :finish_wait -> :finished
        end
      end,
      cancel: fn _request, _opts ->
        send(test_pid, {:cancel_waiting, self()})

        receive do
          :finish_cancel -> {:ok, :cancelled}
        end
      end
    ]

    assert {:ok, request} = Server.start_operation(server, client.id, blocking_spec)
    assert_receive {:await_waiting, await_worker}
    assert {:error, :session_cancel_timeout} = Server.cancel_request_wait(server, client.id, request, [], 0)
    assert_receive {:cancel_waiting, cancel_worker}

    assert Enum.any?(Server.state(server).control_state, fn {_id, control} ->
             control["control"] == "cancel" and control["status"] == "requested"
           end)

    send(cancel_worker, :finish_cancel)
    send(await_worker, :finish_wait)
    assert :finished = Server.await_request(server, request, 1_000)

    assert Enum.any?(Server.state(server).control_state, fn {_id, control} ->
             control["control"] == "cancel" and control["status"] == "terminal"
           end)

    no_cancel_spec = [
      start: fn _owner -> {:ok, %{request_id: "no-cancel"}} end,
      await: fn _request ->
        send(test_pid, {:no_cancel_waiting, self()})

        receive do
          :finish_wait -> :finished
        end
      end
    ]

    assert {:ok, no_cancel_request} = Server.start_operation(server, client.id, no_cancel_spec)
    assert_receive {:no_cancel_waiting, no_cancel_worker}

    assert {:error, :cancel_unsupported} =
             Server.cancel_request(server, client.id, no_cancel_request, [])

    send(no_cancel_worker, :finish_wait)
    assert :finished = Server.await_request(server, no_cancel_request, 1_000)
  end

  test "permission expiry commits from an injected clock and does not restore authority", %{
    server: server,
    session: session
  } do
    client = identity(:client, session)
    assert {:ok, _events} = attach_client(server, client)
    test_pid = self()

    spec = [
      start: fn _owner -> {:ok, %{request_id: "expiring-request"}} end,
      await: fn raw_request ->
        RuntimeResult.pending_review("expiring-request", :runtime_session, raw_request, [
          %{id: "expiring-review", expires_at_ms: 500}
        ])
      end,
      respond_review: fn _decision, _pending, _review, _opts, _owner ->
        send(test_pid, :expired_authority_used)
        :unexpected
      end
    ]

    assert {:ok, request} = Server.start_operation(server, client.id, spec)
    assert %RuntimeResult{} = Server.await_request(server, request, 1_000)

    assert {:error, :stale_result} =
             Server.expire_permission(server, "missing-review", fn -> 500 end)

    assert {:error, :invalid_durable_clock} =
             Server.expire_permission(server, "expiring-review", String)

    assert {:error, :permission_not_expired} =
             Server.expire_permission(server, "expiring-review", fn -> 499 end)

    assert {:ok, :expired} = Server.expire_permission(server, "expiring-review", fn -> 500 end)
    assert {:ok, :expired} = Server.expire_permission(server, "expiring-review", fn -> 900 end)

    assert {:error, :review_not_pending} =
             Server.respond_review(server, client.id, :approve, request, %{id: "expiring-review"}, [])

    refute_receive :expired_authority_used, 20
    assert Server.state(server).permissions["expiring-review"]["decision"] == "expired"
  end

  defp attach_client(server, client) do
    with {:ok, %{events: events}} <- Server.attach(server, client) do
      {:ok, events}
    end
  end

  defp identity(kind, session, opts \\ []) do
    Identity.new!(
      kind,
      opts ++
        [
          session_id: session.id,
          generation: session.generation,
          owner_instance_id: session.owner_instance_id
        ]
    )
  end

  defp client_call(server, session, client, attachment_id, operation) do
    Server.client_operation(
      server,
      %{
        session_id: session.id,
        client_id: client.id,
        attachment_id: attachment_id,
        generation: session.generation,
        owner_instance_id: session.owner_instance_id
      },
      operation
    )
  end
end
