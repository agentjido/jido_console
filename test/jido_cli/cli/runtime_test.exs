defmodule Jido.Cli.Runtime.JidokaTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Runtime.Jidoka, as: Runtime
  alias Jido.Cli.Coding.Setup
  alias Jidoka.Cancellation
  alias Jidoka.Event
  alias Jidoka.Session.Data, as: Session

  test "completes a real asynchronous Jidoka session" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "deterministic answer"}}
    end

    assert {:ok, %Session{} = session} = Runtime.start_session(Jido.Cli.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "hello", self(), llm: llm)
    assert_receive {:jidoka_turn_event, %Event{event: :turn_finished}}, 1_000

    assert {:ok, %Session{}, "deterministic answer"} =
             Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)
  end

  test "returns typed evidence after a forced public cancellation" do
    test_pid = self()

    llm = fn _intent, _journal, _context ->
      send(test_pid, :forced_capability_started)
      Process.sleep(:infinity)
    end

    assert {:ok, %Session{} = session} = Runtime.start_session(Jido.Cli.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "wait", self(), llm: llm)
    assert_receive :forced_capability_started, 1_000
    request_id = request.request_id

    assert {:ok,
            %Cancellation{
              request_id: ^request_id,
              reason: :cancelled,
              forced?: true
            } = cancellation} = Runtime.cancel(request, grace_ms: 1)

    assert {:cancelled, ^cancellation} = Runtime.await(request, timeout: 100)

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

    assert {:ok, %Session{} = session} = Runtime.start_session(Jido.Cli.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "wait", self(), llm: llm)
    assert_receive :cooperative_capability_started, 1_000

    assert {:ok, %Cancellation{forced?: false} = cancellation} =
             Runtime.cancel(request, grace_ms: 500)

    assert {:cancelled, ^cancellation} = Runtime.await(request, timeout: 100)
  end

  test "opens, uses, and closes an extension-backed interactive session" do
    root = Path.join(System.tmp_dir!(), "jido-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "AGENTS.md"), "Use the coding operations.")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, setup} = Setup.prepare(Jido.Cli.DefaultAgent, project_root: root)
    on_exit(fn -> Setup.close(setup) end)

    assert {:ok, %Runtime.Session{} = session} =
             Runtime.start_session(Jido.Cli.DefaultAgent,
               agent_spec_override: setup.spec,
               extension_setup: setup.extension_setup
             )

    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "extension answer"}}
    end

    assert {:ok, %Runtime.Request{} = request} = Runtime.start_turn(session, "hello", self(), llm: llm)

    assert {:ok, %Runtime.Session{} = next_session, "extension answer", []} =
             Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)

    assert :ok = Runtime.close_session(next_session)
    assert :ok = Runtime.close_session(:plain_session)
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
end
