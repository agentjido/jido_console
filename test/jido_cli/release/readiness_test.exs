defmodule Jido.Cli.Release.ReadinessTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Release.Readiness

  test "accepts two equal semantic baselines" do
    source = source()

    runner = fn run_id, _project_root, ^source, _opts ->
      %{"run" => run_id, "summary" => %{"status" => "passed"}}
    end

    assert %{
             "status" => "passed",
             "source" => ^source,
             "runs" => [%{"run" => "run-a"}, %{"run" => "run-b"}],
             "semantic_sha256" => digest
           } = Readiness.baseline!(source: source, baseline_runner: runner)

    assert byte_size(digest) == 64
  end

  test "rejects different semantic baselines" do
    runner = fn run_id, _project_root, _source, _opts ->
      %{"run" => run_id, "summary" => %{"run" => run_id}}
    end

    assert_raise RuntimeError, "clean release baselines differ", fn ->
      Readiness.baseline!(source: source(), baseline_runner: runner)
    end
  end

  test "rejects a dirty source checkout" do
    runner = fn
      "git", ["rev-parse", "HEAD"], _opts -> {String.duplicate("a", 40), 0}
      "git", ["rev-parse", "HEAD^{tree}"], _opts -> {String.duplicate("b", 40), 0}
      "git", ["status" | _args], _opts -> {" M lib/value.ex\n", 0}
    end

    assert_raise RuntimeError, "release-readiness checks require a clean checkout", fn ->
      Readiness.source_identity!(File.cwd!(), runner)
    end
  end

  test "runs the provider-free replay contract through existing product tests" do
    parent = self()

    runner = fn "mix", args, opts ->
      send(parent, {:command, args, opts})
      {"", 0}
    end

    assert %{"check" => "replay", "status" => "passed"} =
             Readiness.run!("replay", command_runner: runner)

    assert_receive {:command, ["test" | tests], opts}
    assert "test/jido_cli/cli/automation/replay_test.exs" in tests
    assert "test/jido_cli/cli/automation/jsonl_test.exs" in tests
    assert opts[:cd] == File.cwd!()
  end

  test "runs the versioned coding scenario oracle" do
    parent = self()

    runner = fn "mix", args, _opts ->
      send(parent, {:golden_command, args})
      {"", 0}
    end

    assert %{"check" => "golden-task", "status" => "passed"} =
             Readiness.run!("golden-task", command_runner: runner)

    assert_receive {:golden_command, args}
    assert "test/integration/coding_scenario_oracle_test.exs" in args
  end

  test "uses the existing deterministic TUI state and layout suite" do
    parent = self()

    runner = fn "mix", args, _opts ->
      send(parent, {:layout_command, args})
      {"", 0}
    end

    assert %{"check" => "tui-layout", "status" => "passed"} =
             Readiness.run!("tui-layout", command_runner: runner)

    assert_receive {:layout_command, args}
    assert "test/jido_cli/cli/tui/editor_test.exs" in args
    assert "test/jido_cli/cli/tui/state_test.exs" in args
    assert "test/jido_cli/cli/tui/view_test.exs" in args
  end

  test "runs the bounded terminal and real PTY suite" do
    parent = self()

    runner = fn "mix", args, _opts ->
      send(parent, {:terminal_command, args})
      {"", 0}
    end

    assert %{"check" => "tui-terminal", "status" => "passed"} =
             Readiness.run!("tui-terminal", command_runner: runner)

    assert_receive {:terminal_command, args}
    assert "test/integration/coding_tui_pty_test.exs" in args
    assert "test/jido_cli/cli/tui_test.exs" in args
    assert "expect" in args
    assert "180000" in args
  end

  test "keeps release measurements separate from a performance claim" do
    collector = fn _opts ->
      %{
        "status" => "passed",
        "package_size_bytes" => 1,
        "help" => %{},
        "version" => %{},
        "first_frame" => %{},
        "runtime_ready" => %{},
        "idle_memory_kib" => %{}
      }
    end

    assert %{"status" => "passed", "claim" => claim} =
             Readiness.run!("measurement", measurement_collector: collector)

    assert claim =~ "not a public performance claim"
  end

  test "checks the first-user support policy" do
    assert %{"status" => "passed", "policy" => policy} = Readiness.run!("support-policy", [])
    assert policy =~ "first-user-support.md"
  end

  test "uses the existing Jidoka dependency checks" do
    runner = fn "mix", _args, _opts -> {"", 0} end

    assert %{"status" => "passed", "command" => command} =
             Readiness.run!("dependency-policy", command_runner: runner)

    assert command =~ "jidoka_dependency_test.exs"
    assert command =~ "jidoka_public_api_boundary_test.exs"
    assert command =~ "cross_repo_test.exs"
  end

  test "checks the Tilde source boundary" do
    assert %{
             "status" => "passed",
             "dependency" => "absent",
             "production_module" => "absent"
           } = Readiness.run!("source-policy", [])
  end

  test "checks immutable and narrow GitHub workflows" do
    assert %{
             "status" => "passed",
             "workflow_count" => 2,
             "immutable_reference_count" => 2,
             "secret_inheritance" => "absent",
             "release_operations" => "absent"
           } = Readiness.run!("workflow-policy", [])
  end

  test "rejects a mutable external workflow dependency" do
    root = Path.join(System.tmp_dir!(), "jido-workflow-policy-#{System.unique_integer([:positive])}")
    workflow = Path.join(root, ".github/workflows/ci.yml")
    File.mkdir_p!(Path.dirname(workflow))
    File.write!(workflow, "jobs:\n  ci:\n    uses: actions/checkout@v6\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert_raise RuntimeError, ~r/mutable workflow reference v6/, fn ->
      Readiness.run!("workflow-policy", project_root: root)
    end
  end
  defp source do
    %{
      "commit" => String.duplicate("a", 40),
      "tree" => String.duplicate("b", 40),
      "mix_lock_sha256" => String.duplicate("c", 64),
      "toolchain" => %{"elixir" => "1", "otp" => "1", "mix" => "1"}
    }
  end
end
