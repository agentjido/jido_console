defmodule Jido.Console.Session.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Runtime.Result, as: RuntimeResult
  alias Jido.Console.Session.{Identity, Server, Supervisor}

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
    assert {:ok, snapshot} = attach_bounded(server, client)
    assert snapshot["payload"]["snapshot_sequence"] == 0
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
    assert {:ok, _} = attach_bounded(server, client)
    assert :ok = Server.detach(server, client)
    assert Process.alive?(server)
    assert {:ok, _} = attach_bounded(server, client)
  end

  test "bounded attachments get one advisory and pull canonical batches", %{
    server: server,
    session: session
  } do
    client = Identity.new!(:client, session_id: session.id)

    assert {:ok, %{attachment: attachment, snapshot: snapshot}} =
             attach_bounded(server, client,
               delivery_limits: %{ack_timeout_ms: 25},
               token_secret: String.duplicate("t", 32)
             )

    assert snapshot["type"] == "attach_snapshot"
    assert snapshot["payload"]["snapshot_sequence"] == 0
    assert snapshot["payload"]["snapshot"]["sequence"] == 0
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
    assert_receive {:jido_console_session, attachment_id, :output_ready}
    assert attachment_id == attachment.id
    refute_receive {:jido_console_session, ^attachment_id, :output_ready}, 20

    assert {:ok, batch} = Server.output(server, session.id, client.id, attachment.id)
    assert batch["type"] == "output_batch"
    assert Enum.map(batch["payload"]["events"], & &1["type"]) == ["run_started"]
    token = batch["payload"]["acknowledgement_token"]

    assert {:error, :ack_required} = Server.output(server, session.id, client.id, attachment.id)

    assert {:error, :delivery_identity_mismatch} =
             Server.output(server, session.id, client.id, "old_attachment")

    assert {:ok, receipt} =
             Server.ack_output(server, session.id, client.id, attachment.id, token)

    assert receipt["through_sequence"] == 1

    send(worker, :finish_bounded)
    assert :done = Server.await_request(server, request, 1_000)
    assert_receive {:jido_console_session, ^attachment_id, :output_ready}

    assert {:ok, terminal_batch} = Server.output(server, session.id, client.id, attachment.id)
    assert Enum.map(terminal_batch["payload"]["events"], & &1["type"]) == ["run_completed"]

    assert_receive {:jido_console_session, ^attachment_id, :output_ready}, 200
    assert {:gap, gap} = Server.output(server, session.id, client.id, attachment.id)
    assert gap["payload"]["reason"] == "acknowledgement_timeout"

    assert {:ok, measurements} = Server.delivery_measurements(server, client.id, attachment.id)
    assert measurements.status == :gapped
    assert measurements.advisory_count == 0
  end

  test "bounded recovery queues output and resumes incremental delivery", %{
    server: server,
    session: session
  } do
    client = Identity.new!(:client, session_id: session.id)

    assert {:ok, %{attachment: attachment}} =
             attach_bounded(server, client,
               delivery_limits: %{ack_timeout_ms: 25},
               token_secret: String.duplicate("r", 32)
             )

    test_pid = self()

    spec = [
      start: fn _owner -> {:ok, %{request_id: "recovery-request"}} end,
      await: fn _request ->
        send(test_pid, {:recovery_await, self()})

        receive do
          :finish_recovery -> :recovered
        end
      end
    ]

    assert {:ok, request} = Server.start_operation(server, client.id, spec)
    assert_receive {:recovery_await, worker}
    assert_receive {:jido_console_session, attachment_id, :output_ready}
    assert attachment_id == attachment.id
    assert {:ok, _batch} = Server.output(server, session.id, client.id, attachment.id)

    assert_receive {:jido_console_session, ^attachment_id, :output_ready}, 200
    assert {:gap, gap} = Server.output(server, session.id, client.id, attachment.id)

    assert {:ok, snapshot} =
             Server.begin_recovery(
               server,
               session.id,
               client.id,
               attachment.id,
               gap["payload"]["gap_id"]
             )

    send(worker, :finish_recovery)
    assert :recovered = Server.await_request(server, request, 1_000)

    assert {:error, :delivery_recovering} =
             Server.output(server, session.id, client.id, attachment.id)

    assert {:ok, suffix} =
             Server.replay_recovery(
               server,
               session.id,
               client.id,
               attachment.id,
               snapshot["payload"]["recovery_token"]
             )

    assert Enum.map(suffix["payload"]["events"], & &1["type"]) == ["run_completed"]

    assert {:ok, receipt} =
             Server.complete_recovery(
               server,
               session.id,
               client.id,
               attachment.id,
               suffix["payload"]["completion_token"]
             )

    assert receipt["payload"]["through_sequence"] == 2
    assert :empty = Server.output(server, session.id, client.id, attachment.id)

    next_spec = [
      start: fn _owner -> {:ok, %{request_id: "post-recovery-request"}} end,
      await: fn _request -> :post_recovery_done end
    ]

    assert {:ok, next_request} = Server.start_operation(server, client.id, next_spec)
    assert :post_recovery_done = Server.await_request(server, next_request, 1_000)
    assert_receive {:jido_console_session, ^attachment_id, :output_ready}
    assert {:ok, next_batch} = Server.output(server, session.id, client.id, attachment.id)
    assert Enum.map(next_batch["payload"]["events"], & &1["payload"]["sequence"]) == [3, 4]
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

    assert {:error, :cross_session_result} = attach_bounded(server, foreign)
    assert {:error, :not_attached} = Server.detach(server, client)
    assert {:error, :not_attached} = Server.runtime_info(server, client.id)
    assert {:error, :not_attached} = Server.configure_runtime(server, client.id, FakeRuntime, :agent, [])

    assert {:ok, _snapshot} = attach_bounded(server, client)
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
    assert {:ok, _snapshot} = attach_bounded(server, client)
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
    client = Identity.new!(:client, session_id: session.id)
    assert {:ok, _snapshot} = attach_bounded(server, client)
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

    assert_receive {:review_response, :approve, %RuntimeResult{}, %{id: "review"}, [source: :test], ^server}
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
    send(cancel_worker, :finish_cancel)
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

  defp attach_bounded(server, client) do
    with {:ok, %{snapshot: snapshot}} <- Server.attach(server, client) do
      {:ok, snapshot}
    end
  end

  defp attach_bounded(server, client, opts), do: Server.attach(server, client, opts)
end
