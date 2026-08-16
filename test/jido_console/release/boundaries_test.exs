defmodule Jido.Console.Release.BoundariesTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Release.Boundaries
  alias Jido.Console.Coding.Environment
  alias Jido.Console.Coding.Local.Adapter
  alias Jidoka.CodingPack.Workspace

  test "cleans a controlled command directory when sandbox admission fails" do
    root = Path.join(System.tmp_dir!(), "jido-boundary-cleanup-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspace")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, environment_contract} =
             Environment.resolve("coding.restricted", jido_home: Path.join(root, "home"))

    request = %{
      "command" => "git",
      "args" => ["status"],
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 1_000,
      "max_output_bytes" => 1_024,
      "network" => false,
      "command_class" => "git",
      "mutation" => "read"
    }

    opts = [
      workspace: Workspace.new!(root: workspace_root, access: [:shell]),
      executables: %{"git" => System.find_executable("git")},
      environment_contract: environment_contract
    ]

    assert {:error, :local_coding_sandbox_unavailable} = Adapter.execute(nil, request, opts)
    assert {:ok, []} = File.ls(environment_contract.tmpdir)
  end

  test "denies controlled traversal and symbolic-link escapes twice" do
    result = Boundaries.file_boundary!()

    assert result["status"] == "passed"
    assert result["repeat_runs"] == 2
    assert result["risk_control"] == "jido_console-m1e15"
    assert Enum.all?(result["cases"], &(&1["classification"] == "denied"))
    assert byte_size(result["canary_sha256"]) == 64
    refute inspect(result) =~ "jido-controlled-boundary-canary"
  end

  test "rejects a changed file-boundary result with the case name" do
    assert_raise RuntimeError, ~r/parent_traversal expected denied but got known_risk/, fn ->
      Boundaries.file_boundary!(probe: fn _workspace, _request -> {:ok, %{content: "not recorded"}} end)
    end
  end

  test "validates controlled runtime classifications without a host probe" do
    network = fn ->
      [
        %{"name" => "loopback", "classification" => "denied"},
        %{"name" => "external", "classification" => "denied"}
      ]
    end

    processes = fn ->
      Enum.map(~w(success rejection cancellation timeout owner_exit), fn name ->
        %{"name" => name, "classification" => "denied", "runner_cleanup" => "passed"}
      end)
    end

    assert %{"status" => "passed", "public_endpoints_contacted" => 0} =
             Boundaries.runtime_boundary!(network_probe: network, process_probe: processes)
  end

  @tag :darwin
  test "probes the local sandbox and cleans every controlled child process" do
    result = Boundaries.runtime_boundary!()

    assert Enum.all?(result["processes"], &(&1["runner_cleanup"] == "passed"))
    refute inspect(result) =~ ~r/"(?:pid|child_pid|parent_pid)"/
  end
end
