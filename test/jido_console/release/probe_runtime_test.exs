defmodule Jido.Console.Release.ProbeRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.ProbeRuntime
  alias Jido.Console.Release.ProbeRuntime.Result

  setup do
    root = Path.join(System.tmp_dir!(), "jido-probe-runtime-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  test "validates every probe path before it starts a session", %{root: root, workspace: workspace} do
    expected = Path.join(root, "expected.ex")
    File.write!(expected, "expected")

    assert {:error, :release_probe_workspace_missing} =
             ProbeRuntime.start_session(nil, probe_mode: :workflow)

    assert {:error, :release_probe_expected_file_missing} =
             ProbeRuntime.start_session(nil, probe_mode: :workflow, probe_workspace: workspace)

    assert {:error, :release_probe_log_directory_missing} =
             ProbeRuntime.start_session(nil,
               probe_mode: :workflow,
               probe_workspace: workspace,
               probe_expected: expected,
               probe_log: Path.join(root, "missing/probe.jsonl")
             )

    assert {:error, :release_probe_verifier_invalid} =
             ProbeRuntime.start_session(nil,
               probe_mode: :workflow,
               probe_workspace: workspace,
               probe_expected: expected,
               probe_log: Path.join(root, "probe.jsonl"),
               probe_verifier: :invalid
             )

    assert {:error, {:invalid_release_probe_mode, :invalid}} =
             ProbeRuntime.start_session(nil, probe_mode: :invalid)

    assert {:ok, success} = ProbeRuntime.start_session(nil, probe_log: "relative.log")
    assert :ok = ProbeRuntime.close_session(success)
    assert :ok = ProbeRuntime.close_session(:invalid)
  end

  test "normalizes workflow read, review, verify, cancel, and fallback outcomes", context do
    expected = Path.join(context.root, "expected.ex")
    log = Path.join(context.root, "probe.jsonl")
    File.write!(expected, "defmodule Expected do\nend\n")

    assert {:ok, session} =
             ProbeRuntime.start_session(nil,
               probe_mode: :workflow,
               probe_workspace: context.workspace,
               probe_expected: expected,
               probe_log: log,
               probe_verifier: :private_runtime
             )

    assert {:ok, first} = ProbeRuntime.start_turn(session, "inspect", self(), [])
    assert %Result{outcome: %Result.Error{}} = ProbeRuntime.await(first, [])

    assert {:ok, second} = ProbeRuntime.start_turn(session, "edit", self(), [])
    assert %Result{outcome: %Result.PendingReview{reviews: [review]}} = pending = ProbeRuntime.await(second, [])
    assert %Result{outcome: %Result.Error{}} = ProbeRuntime.approve(pending, %{}, stream_to: self())
    assert %Result{outcome: %Result.Error{}} = ProbeRuntime.approve(pending, review, stream_to: self())
    assert %Result{outcome: %Result.Error{approval: :denied}} = ProbeRuntime.deny(pending, review, [])
    assert {:ok, cancellation} = ProbeRuntime.cancel(second, [])
    assert cancellation.request_id == second.request_id

    assert {:ok, third} = ProbeRuntime.start_turn(session, "verify", self(), [])
    assert %Result{outcome: %Result.Error{}} = ProbeRuntime.await(third, [])

    assert {:ok, fourth} = ProbeRuntime.start_turn(session, "cancel", self(), [])
    assert {:ok, _cancellation} = ProbeRuntime.cancel(fourth, [])

    assert {:ok, fifth} = ProbeRuntime.start_turn(session, "fallback", self(), [])
    assert %Result{outcome: %Result.Ok{content: "Release probe completed."}} = ProbeRuntime.await(fifth, [])

    assert %Result{outcome: %Result.Error{}} = ProbeRuntime.approve(ProbeRuntime.await(first, []), review, [])
    assert :ok = ProbeRuntime.close_session(session)
    assert File.read!(log) =~ "session_closed"
  end
end
