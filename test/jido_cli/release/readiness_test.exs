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

  defp source do
    %{
      "commit" => String.duplicate("a", 40),
      "tree" => String.duplicate("b", 40),
      "mix_lock_sha256" => String.duplicate("c", 64),
      "toolchain" => %{"elixir" => "1", "otp" => "1", "mix" => "1"}
    }
  end
end
