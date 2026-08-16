defmodule Jido.Console.Session.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Runtime.Result, as: RuntimeResult
  alias Jido.Console.Session.{Identity, Input, Server, Supervisor}

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

  test "runtime configuration validates ownership and always closes replaced resources", %{
    server: server,
    session: session
  } do
    client = Identity.new!(:client, session_id: session.id)
    foreign = Identity.new!(:client, session_id: Identity.new!(:session).id)

    assert {:error, :cross_session_result} = Server.attach(server, foreign)
    assert {:error, :not_attached} = Server.detach(server, client)
    assert {:error, :not_attached} = Server.runtime_info(server, client.id)
    assert {:error, :not_attached} = Server.configure_runtime(server, client.id, FakeRuntime, :agent, [])

    assert {:ok, _snapshot} = Server.attach(server, client)
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
    client = Identity.new!(:client, session_id: session.id)
    session_id = session.id
    assert {:ok, _snapshot} = Server.attach(server, client)
    assert {:error, :runtime_not_configured} = Server.start_turn(server, client.id, "prompt", [])
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
    assert_receive {:operation_started, ^server}
    assert_receive {:operation_awaiting, await_worker, raw_request}
    assert_receive {:session_runtime_started, ^session_id, ^request}

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
    assert_receive {:session_control_result, ^session_id, ^request, {:ok, :cancelled}}

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
    client = Identity.new!(:client, session_id: session.id)
    session_id = session.id
    assert {:ok, _snapshot} = Server.attach(server, client)
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
    assert_receive {:session_runtime_result, ^session_id, ^request, %RuntimeResult{}}
    assert {:ok, %{active_request: ^request}} = Server.runtime_info(server, client.id)

    assert {:ok, :requested} =
             Server.respond_review(server, client.id, :approve, request, %{id: "review"}, source: :test)

    assert_receive {:review_response, :approve, %RuntimeResult{}, %{id: "review"}, [source: :test], ^server}
    assert :review_complete = Server.await_request(server, request, 1_000)

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
    send(cancel_worker, :finish_cancel)
    assert_receive {:session_control_result, ^session_id, ^request, {:ok, :cancelled}}
    send(await_worker, :finish_wait)
    assert :finished = Server.await_request(server, request, 1_000)

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
end
