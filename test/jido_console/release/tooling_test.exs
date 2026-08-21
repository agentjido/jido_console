defmodule Jido.Console.Release.ToolingTest do
  use ExUnit.Case, async: false

  alias CodingScenario.Oracle
  alias Jido.Console.Release.{Acceptance, Artifact, LicenseAudit, Local, ProbeRuntime}
  alias Jido.Console.Release.ProbeRuntime.Result

  setup do
    root = Path.join(System.tmp_dir!(), "jido-release-tooling-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "computes stable startup statistics with a separate cold result" do
    values = [900, 100, 120, 110, 130]

    assert Acceptance.statistics!(values) == %{
             "cold_ms" => 900.0,
             "warm_runs" => 4,
             "warm_median_ms" => 115.0,
             "warm_p95_ms" => 130.0,
             "warm_samples_ms" => [100.0, 120.0, 110.0, 130.0]
           }
  end

  test "creates one private isolated product home for artifact acceptance", %{root: root} do
    operator_home = System.user_home!()

    assert %{"JIDO_HOME" => home} = Acceptance.acceptance_environment!(root)
    assert home == Path.join(root, "jido-home")
    refute String.starts_with?(home, operator_home <> "/")
    assert File.dir?(home)
    assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o700
  end

  test "detects a changed file digest", %{root: root} do
    path = Path.join(root, "artifact")
    File.write!(path, "first")
    first = Artifact.sha256_file(path)
    File.write!(path, "second")
    second = Artifact.sha256_file(path)

    assert byte_size(first) == 64
    assert byte_size(second) == 64
    refute first == second
  end

  test "rejects dirty publication and permits an explicit development override" do
    assert_raise RuntimeError, ~r/worktree is dirty/, fn ->
      Local.validate_source!(%{dirty: true}, false)
    end

    assert :ok = Local.validate_source!(%{dirty: true}, true)
    assert :ok = Local.validate_source!(%{dirty: false}, false)
  end

  test "runs shared source gates through precommit in release order", %{root: root} do
    test = self()

    assert Jido.Console.MixProject.project()[:aliases][:precommit] == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "xref graph --format cycles --fail-above 0",
             "credo",
             "dialyzer",
             "doctor --raise"
           ]

    command_runner = fn command, args, opts ->
      send(test, {:command, command, args, opts[:cd], opts[:env]})
      {"", 0}
    end

    cross_repo_runner = fn project_root ->
      send(test, {:cross_repo, project_root})
      %{}
    end

    assert :ok =
             Local.source_gates!(root,
               command_runner: command_runner,
               cross_repo_runner: cross_repo_runner
             )

    assert_receive {:command, "mix", ["deps.get", "--check-locked"], ^root, []}
    assert_receive {:command, "mix", ["precommit"], ^root, []}
    assert_receive {:command, "mix", ["coveralls"], ^root, [{"MIX_ENV", "test"}]}
    assert_receive {:cross_repo, ^root}
    refute_receive _other
  end

  test "stops release source gates on a failed precommit", %{root: root} do
    test = self()

    command_runner = fn _command, args, _opts ->
      send(test, {:command, args})
      if args == ["precommit"], do: {"failed", 23}, else: {"", 0}
    end

    cross_repo_runner = fn _project_root -> send(test, :cross_repo) end

    assert_raise RuntimeError, "release command mix failed with status 23", fn ->
      Local.source_gates!(root,
        command_runner: command_runner,
        cross_repo_runner: cross_repo_runner
      )
    end

    assert_receive {:command, ["deps.get", "--check-locked"]}
    assert_receive {:command, ["precommit"]}
    refute_receive {:command, ["coveralls"]}
    refute_receive :cross_repo
  end

  test "creates deterministic reviewed notice records", %{root: root} do
    license = Path.join(root, "LICENSE")
    File.write!(license, "license text\n")

    component = %{
      name: "sample",
      version: "1.0.0",
      kind: :dependency,
      source: "hex://hexpm/sample@1.0.0",
      licenses: ["MIT"],
      license_file: "deps/sample/LICENSE",
      license_path: license,
      native_files: ["priv/sample.dylib"]
    }

    first = LicenseAudit.notices([component])
    assert first == LicenseAudit.notices([component])
    assert first =~ "sample 1.0.0"
    assert first =~ "priv/sample.dylib"
    assert first =~ "license text"
  end

  test "the TUI release probe records one turn", %{root: root} do
    log = Path.join(root, "turns.log")
    previous = System.get_env("JIDO_RELEASE_TUI_PROBE_LOG")
    System.put_env("JIDO_RELEASE_TUI_PROBE_LOG", log)

    on_exit(fn ->
      if previous,
        do: System.put_env("JIDO_RELEASE_TUI_PROBE_LOG", previous),
        else: System.delete_env("JIDO_RELEASE_TUI_PROBE_LOG")
    end)

    assert {:ok, session} = ProbeRuntime.start_session(Jido.Console.DefaultAgent, probe_log: log)
    assert {:ok, request} = ProbeRuntime.start_turn(session, "hello", self(), [])
    assert_receive {:jidoka_turn_event, _event}
    assert_receive {:jidoka_turn_event, _event}

    assert %Result{session: ^session, outcome: %Result.Ok{content: "Release probe completed."}} =
             ProbeRuntime.await(request, [])

    assert :ok = ProbeRuntime.close_session(session)
    assert [_one_turn] = log |> File.read!() |> String.split("\n", trim: true)
  end

  test "the workflow probe verifies inside the private runtime", %{root: root} do
    fixture = Oracle.materialize!(Path.join(root, "repository"))
    expected = Path.join(root, "expected.ex")
    log = Path.join(root, "workflow.jsonl")
    File.write!(expected, Oracle.expected_content!("lib/rate_limiter.ex"))

    assert {:ok, session} =
             ProbeRuntime.start_session(Jido.Console.DefaultAgent,
               probe_mode: :workflow,
               probe_workspace: fixture.root,
               probe_expected: expected,
               probe_log: log,
               probe_verifier: :private_runtime
             )

    assert {:ok, first} = ProbeRuntime.start_turn(session, "inspect", self(), [])
    assert %Result{outcome: %Result.Ok{}} = ProbeRuntime.await(first, [])
    assert {:ok, second} = ProbeRuntime.start_turn(session, "implement", self(), [])
    pending = ProbeRuntime.await(second, [])
    assert %Result{outcome: %Result.PendingReview{reviews: [review]}} = pending

    assert %Result{outcome: %Result.Ok{approval: :approved}} =
             ProbeRuntime.approve(pending, review, stream_to: self())

    assert {:ok, third} = ProbeRuntime.start_turn(session, "verify", self(), [])

    assert %Result{outcome: %Result.Ok{}, raw: "private runtime behavior checks passed"} =
             ProbeRuntime.await(third, [])

    assert :ok = ProbeRuntime.close_session(session)

    records = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert %{
             "command" => "mix test",
             "event" => "verification",
             "runner" => "private_runtime",
             "status" => "passed"
           } in records
  end
end
