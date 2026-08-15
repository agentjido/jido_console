defmodule Jido.Console.Runtime.JidokaTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Runtime.Jidoka, as: Runtime
  alias Jido.Console.Coding.Setup
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Cancellation
  alias Jidoka.Event

  test "completes a real asynchronous Jidoka session" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "deterministic answer"}}
    end

    assert {:ok, %Runtime.Session{} = session} = Runtime.start_session(Jido.Console.DefaultAgent, [])
    assert session.extension_host == nil
    assert session.runtime_opts == []
    assert session.local_resources == nil

    assert {:ok, %Runtime.Request{} = request} = Runtime.start_turn(session, "hello", self(), llm: llm)

    assert request.request_id == request.request.request_id
    assert request.runtime_opts[:request_id] == request.request_id
    assert request.runtime_opts[:llm] == llm
    assert request.runtime_opts[:stream]
    assert request.runtime_opts[:stream_to] == self()

    assert_receive {:jidoka_turn_event, %Event{event: :turn_finished, request_id: request_id}}, 5_000
    assert request_id == request.request_id

    assert %Runtime.Result{
             request_id: ^request_id,
             status: :ok,
             session: %Runtime.Session{},
             content: "deterministic answer",
             error: nil,
             cancellation: nil,
             snapshot: nil,
             pending_reviews: []
           } = result = Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)

    assert result.runtime_opts == request.runtime_opts
    assert result.extension_host == session.extension_host
    assert result.local_resources == session.local_resources
    assert result.handle == request
  end

  test "normalizes a failed turn without dropping its CLI session" do
    llm = fn _intent, _journal, _context -> {:error, :offline} end

    assert {:ok, %Runtime.Session{} = session} = Runtime.start_session(Jido.Console.DefaultAgent, [])
    assert {:ok, %Runtime.Request{} = request} = Runtime.start_turn(session, "fail", self(), llm: llm)

    assert %Runtime.Result{
             request_id: request_id,
             status: :error,
             session: ^session,
             error: error,
             raw: {:error, raw_error}
           } = result = Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)

    assert request_id == request.request_id
    assert raw_error == error
    assert result.runtime_opts == request.runtime_opts
    assert result.handle == request
  end

  test "normalizes hibernation without a pending review" do
    llm = fn _intent, _journal, _context -> flunk("checkpoint hibernation must precede the model call") end

    assert {:ok, %Runtime.Session{} = session} = Runtime.start_session(Jido.Console.DefaultAgent, [])

    assert {:ok, %Runtime.Request{} = request} =
             Runtime.start_turn(session, "pause", self(), llm: llm, checkpoint: :after_prompt)

    assert_receive {:jidoka_turn_event, %Event{event: :turn_hibernated, request_id: request_id}}, 5_000

    assert %Runtime.Result{
             request_id: ^request_id,
             status: :hibernated,
             session: %Runtime.Session{},
             snapshot: %Jidoka.Snapshot{},
             pending_reviews: [],
             approval: nil
           } = result = Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)

    assert result.runtime_opts == request.runtime_opts
    assert result.extension_host == session.extension_host
    assert result.local_resources == session.local_resources
  end

  test "returns typed evidence after a forced public cancellation" do
    test_pid = self()

    llm = fn _intent, _journal, _context ->
      send(test_pid, :forced_capability_started)
      Process.sleep(:infinity)
    end

    assert {:ok, %Runtime.Session{} = session} = Runtime.start_session(Jido.Console.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "wait", self(), llm: llm)
    assert_receive :forced_capability_started, 5_000
    request_id = request.request_id

    assert {:ok,
            %Cancellation{
              request_id: ^request_id,
              reason: :cancelled,
              forced?: true
            } = cancellation} = Runtime.cancel(request, grace_ms: 1)

    assert %Runtime.Result{
             request_id: ^request_id,
             status: :cancelled,
             session: ^session,
             cancellation: ^cancellation,
             raw: {:cancelled, ^cancellation}
           } = result = Runtime.await(request, timeout: 100)

    assert result.runtime_opts == request.runtime_opts

    assert_receive {:jidoka_turn_event, %Event{event: :turn_failed, data: %{reason: :cancelled}}},
                   1_000

    refute_receive {:jidoka_turn_event, %Event{event: :turn_finished}}, 20
  end

  test "returns typed evidence after a cooperative public cancellation" do
    test_pid = self()

    llm = fn _intent, _journal, context ->
      send(test_pid, :cooperative_capability_started)
      wait_for_cancellation(context, 1_000)
      {:error, :cancelled}
    end

    assert {:ok, %Runtime.Session{} = session} = Runtime.start_session(Jido.Console.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "wait", self(), llm: llm)
    assert_receive :cooperative_capability_started, 5_000

    assert {:ok, %Cancellation{forced?: false} = cancellation} =
             Runtime.cancel(request, grace_ms: 500)

    assert %Runtime.Result{status: :cancelled, session: ^session, cancellation: ^cancellation} =
             Runtime.await(request, timeout: 100)
  end

  test "opens, uses, and closes an extension-backed interactive session" do
    root = Path.join(System.tmp_dir!(), "jido-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "AGENTS.md"), "Use the coding operations.")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, setup} = Setup.prepare(Jido.Console.DefaultAgent, project_root: root)
    on_exit(fn -> Setup.close(setup) end)

    assert {:ok, %Runtime.Session{} = session} =
             Runtime.start_session(Jido.Console.DefaultAgent,
               agent_spec_override: setup.spec,
               extension_setup: setup.extension_setup,
               local_resources: setup.local_resources
             )

    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "extension answer"}}
    end

    assert {:ok, %Runtime.Request{} = request} = Runtime.start_turn(session, "hello", self(), llm: llm)
    assert request.extension_host == session.extension_host
    assert request.local_resources == setup.local_resources

    assert %Runtime.Result{
             status: :ok,
             session: %Runtime.Session{} = next_session,
             content: "extension answer",
             coding_reviews: [],
             extension_host: extension_host,
             local_resources: local_resources
           } = Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)

    assert extension_host == session.extension_host
    assert local_resources == setup.local_resources
    assert next_session.runtime_opts == session.runtime_opts
    assert next_session.extension_host == session.extension_host
    assert next_session.local_resources == session.local_resources

    assert :ok = Runtime.close_session(next_session)
    assert :ok = Runtime.close_session(:plain_session)
  end

  test "keeps the wrapper through hibernation, pending review, approval, and denial" do
    spec =
      Spec.new!(
        id: "runtime_review",
        model: %{provider: :test, id: "model"},
        instructions: "Use the operation, then answer.",
        operations: [
          Operation.new!(
            name: "unsafe_change",
            description: "Change one value.",
            idempotency: :unsafe_once,
            approval: true
          )
        ]
      )

    llm = fn _intent, journal, _context ->
      if Enum.any?(journal.results, fn {_id, result} -> result.kind == :operation end) do
        {:ok, %{type: :final, content: "approved change complete"}}
      else
        {:ok, %{type: :operation, name: "unsafe_change", arguments: %{}}}
      end
    end

    operations = fn _intent, _journal, _context -> {:ok, %{changed: true}} end

    assert {:ok, %Runtime.Session{} = session} =
             Runtime.start_session(Jido.Console.DefaultAgent, agent_spec_override: spec)

    assert {:ok, %Runtime.Request{} = request} =
             Runtime.start_turn(session, "change", self(), llm: llm, operations: operations)

    assert_receive {:jidoka_turn_event, %Event{event: :turn_hibernated, request_id: request_id}}, 5_000

    assert %Runtime.Result{
             request_id: ^request_id,
             status: :pending_review,
             session: %Runtime.Session{},
             snapshot: %Jidoka.Snapshot{},
             pending_reviews: [review],
             approval: nil
           } = paused = Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)

    assert paused.runtime_opts == request.runtime_opts
    assert paused.extension_host == session.extension_host
    assert paused.local_resources == session.local_resources

    test_pid = self()
    stream_probe = spawn(fn -> stream_probe(test_pid) end)

    assert %Runtime.Result{
             request_id: ^request_id,
             status: :ok,
             session: %Runtime.Session{},
             content: "approved change complete",
             approval: :approved
           } = approved = Runtime.approve(paused, review, stream_to: stream_probe)

    assert_receive {:review_stream, {:jidoka_turn_event, %Event{event: :turn_finished, request_id: ^request_id}}},
                   1_000

    send(stream_probe, :stop)

    assert approved.runtime_opts == request.runtime_opts

    assert {:ok, %Runtime.Request{} = denied_request} =
             Runtime.start_turn(approved.session, "change again", self(), llm: llm, operations: operations)

    assert_receive {:jidoka_turn_event, %Event{event: :turn_hibernated, request_id: denied_id}}, 5_000

    assert %Runtime.Result{status: :pending_review, pending_reviews: [denied_review]} =
             denied_paused =
             Runtime.await(denied_request, timeout: 30_000, cancel_on_timeout: false)

    assert %Runtime.Result{
             request_id: ^denied_id,
             status: :error,
             session: %Runtime.Session{},
             approval: :denied,
             error: denied_error
           } = denied = Runtime.deny(denied_paused, denied_review, [])

    assert denied_error != nil
    assert denied.runtime_opts == denied_request.runtime_opts
  end

  defp wait_for_cancellation(_context, 0), do: :ok

  defp wait_for_cancellation(context, attempts_left) do
    if Cancellation.requested?(context) do
      :ok
    else
      Process.sleep(1)
      wait_for_cancellation(context, attempts_left - 1)
    end
  end

  defp stream_probe(test_pid) do
    receive do
      :stop ->
        :ok

      message ->
        send(test_pid, {:review_stream, message})
        stream_probe(test_pid)
    end
  end
end
