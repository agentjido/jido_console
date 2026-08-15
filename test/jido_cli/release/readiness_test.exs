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

  defp source do
    %{
      "commit" => String.duplicate("a", 40),
      "tree" => String.duplicate("b", 40),
      "mix_lock_sha256" => String.duplicate("c", 64),
      "toolchain" => %{"elixir" => "1", "otp" => "1", "mix" => "1"}
    }
  end
end
