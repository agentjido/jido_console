defmodule Jido.Console.Coding.LocalTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Coding.{Local, Setup, WorkspaceConfig}
  alias Jido.Console.Coding.Local.MutationBackend
  alias Jido.Console.ExecutionPolicy.Registry
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jidoka.CodingPack.{Edit, Verify, Workspace}
  alias Jidoka.ExecutionEnvironment.Manager

  setup do
    root = Path.join(System.tmp_dir!(), "jido-local-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule LocalScenario.MixProject do\n  use Mix.Project\n  def project, do: [app: :local_scenario, version: \"0.1.0\", deps: []]\nend\n"
    )

    File.write!(Path.join(root, "lib/value.ex"), "defmodule Value do\n  def answer, do: 41\nend\n")
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(root, "test/value_test.exs"),
      "defmodule ValueTest do\n  use ExUnit.Case\n  test \"answer\", do: assert(Value.answer() == 42)\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "requires an explicit root and prepares local resources for the default profile", %{root: root} do
    assert {:error, {:execution_policy_root_required, "coding.trusted-workspace"}} =
             Setup.prepare(Jido.Console.DefaultAgent, coding_profile: Local.profile_id())

    assert {:ok, setup} =
             Setup.prepare(Jido.Console.DefaultAgent,
               project_root: root,
               jido_home: Path.join(root, "home")
             )

    on_exit(fn -> Setup.close(setup) end)
    assert Enum.sort(setup.workspace.access) == Enum.sort([:read, :write, :shell, :git, :verify])
    assert setup.profile_id == "coding.restricted"

    if System.find_executable("git") && System.find_executable("mix") do
      assert setup.local_resources
      assert ExtensionSetup.recover_coding_errors?(setup.extension_setup)
    end
  end

  test "canonical and legacy trusted IDs use the same workspace root gate", %{root: root} do
    assert {:error, :local_coding_root_required} =
             WorkspaceConfig.build("coding.local", project_root: nil)

    assert {:error, :local_coding_root_required} =
             WorkspaceConfig.build("coding.trusted-workspace", project_root: nil)

    assert {:ok, from_alias} = WorkspaceConfig.build("coding.local", project_root: root)

    assert {:ok, from_canonical} =
             WorkspaceConfig.build("coding.trusted-workspace", project_root: root)

    assert from_alias.execution_profile == "coding.trusted-workspace"
    assert from_alias == from_canonical
  end

  test "local policy validates allowed requests and denies unsupported lifecycle actions", %{root: root} do
    workspace =
      Workspace.new!(
        root: root,
        access: [:read, :write, :shell, :git, :verify],
        execution_profile: Local.profile_id()
      )

    contract = environment_contract(root)
    record = Registry.new!() |> Registry.fetch!(contract.execution_policy_id)

    assert {:ok, local} = Local.prepare(record, workspace, contract)
    resources = local.resources
    manager = resources.manager
    mutation_state = resources.mutation_state

    assert {:ok, handle, _evidence} = Manager.acquire(manager, resources.binding)

    assert {:error, %Jidoka.ExecutionEnvironment.Error{}} =
             Manager.execute(manager, handle, %{
               "command" => "git",
               "mutation" => "read",
               "network" => false
             })

    assert {:ok, _evidence} = Manager.close(manager, handle)
    assert {:ok, handle, _evidence} = Manager.acquire(manager, resources.binding)

    assert {:error, %Jidoka.ExecutionEnvironment.Error{}} =
             Manager.checkpoint(manager, handle, resources.binding)

    assert :ok = Local.close(resources)
    refute Process.alive?(manager)
    refute Process.alive?(mutation_state)
    assert :ok = Local.close(resources)
  end

  @tag :darwin
  test "edits and verifies only through the trusted local ports", %{root: root} do
    workspace =
      Workspace.new!(
        root: root,
        access: [:read, :write, :shell, :git, :verify],
        limits: %{max_shell_timeout_ms: 120_000},
        execution_profile: Local.profile_id()
      )

    contract = environment_contract(root)
    record = Registry.new!() |> Registry.fetch!(contract.execution_policy_id)
    assert {:ok, local} = Local.prepare(record, workspace, contract)
    on_exit(fn -> Local.close(local.resources) end)
    assert local.resources.environment_contract === contract
    assert local.resources.binding.profile_id == contract.execution_policy_id

    assert {:ok, edit} =
             Edit.run(workspace, local.mutation, %{
               "path" => "lib/value.ex",
               "old_text" => "def answer, do: 41",
               "new_text" => "def answer, do: 42",
               "expected_occurrences" => 1
             })

    assert edit["path"] == "lib/value.ex"
    assert edit["write_method"] == "atomic_replace"

    assert {:ok, result} = Verify.run(workspace, local.verify, %{"helper_id" => "mix-test"})
    assert result["passed"]
    assert result["status"] == "passed"
    assert result["exit_status"] == 0
  end

  @tag :darwin
  test "does not expose the general shell tool", %{root: root} do
    assert {:ok, setup} =
             Setup.prepare(Jido.Console.DefaultAgent,
               coding_profile: Local.profile_id(),
               project_root: root
             )

    on_exit(fn -> Setup.close(setup) end)
    {:ok, session} = Jidoka.Session.Data.start(setup.spec, session_id: "local-tool-list")
    request = Enum.find(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    registry = ExtensionSetup.registry(setup.extension_setup)
    {:ok, host} = Jidoka.Extension.Host.open(session, [request], registry, :interactive)
    {:ok, compiled} = Jidoka.Operation.Source.compile(Jidoka.Extension.Host.operation_sources(host))
    names = Enum.map(compiled.operations, & &1.name)

    assert "coding.edit" in names
    assert "coding.verify" in names
    refute "coding.shell" in names
    Jidoka.Extension.Host.close(host)
  end

  @tag :darwin
  test "stops local resources when later setup fails", %{root: root} do
    {:links, before_links} = Process.info(self(), :links)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_entries_invalid}} =
             Setup.prepare(Jido.Console.DefaultAgent,
               coding_profile: Local.profile_id(),
               project_root: root,
               coding_replace_tools: "invalid"
             )

    {:links, after_links} = Process.info(self(), :links)
    assert MapSet.new(after_links) == MapSet.new(before_links)
  end

  @tag :darwin
  test "stops a command when streamed output reaches its limit", %{root: root} do
    workspace =
      Workspace.new!(
        root: root,
        access: [:shell],
        execution_profile: Local.profile_id()
      )

    request = %{
      "command" => "git",
      "args" => [],
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 5_000,
      "max_output_bytes" => 1_024,
      "network" => false,
      "command_class" => "git",
      "mutation" => "read"
    }

    assert {:ok, result, _evidence} =
             Jido.Console.Coding.Local.Adapter.execute(nil, request,
               workspace: workspace,
               environment_contract: environment_contract(root),
               executables: %{
                 "git" => System.find_executable("yes"),
                 "sandbox-exec" => System.find_executable("sandbox-exec")
               }
             )

    assert result["status"] == "error"
    assert result["exit_status"] == nil
    assert result["stdout_truncated"]
    assert byte_size(result["stdout"]) <= 1_024

    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, fn message -> match?({port, _data} when is_port(port), message) end)
  end

  @tag :darwin
  test "stops the command process at the wall-time limit", %{root: root} do
    executable = Path.join(root, "long-command")
    pid_file = Path.join(root, "long-command.pid")

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s' \"$$\" > \"#{pid_file}\"\nexec sleep 10\n"
    )

    File.chmod!(executable, 0o700)
    workspace = Workspace.new!(root: root, access: [:shell])

    request = %{
      "command" => "git",
      "args" => [],
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 1_000,
      "max_output_bytes" => 1_024,
      "network" => false,
      "command_class" => "git",
      "mutation" => "read"
    }

    assert {:ok, %{"status" => "timeout"}, _evidence} =
             Jido.Console.Coding.Local.Adapter.execute(nil, request,
               workspace: workspace,
               environment_contract: environment_contract(root),
               executables: %{
                 "git" => executable,
                 "sandbox-exec" => System.find_executable("sandbox-exec")
               }
             )

    command_pid = pid_file |> File.read!() |> String.trim()
    {_output, status} = System.cmd("/bin/kill", ["-0", command_pid], stderr_to_stdout: true)
    refute status == 0
  end

  @tag :darwin
  test "the operating-system sandbox denies non-local network access", %{root: root} do
    workspace = Workspace.new!(root: root, access: [:shell])
    args = ["-u", "-w", "1", "-z", "192.0.2.1", "9"]
    {_output, control_status} = System.cmd("/usr/bin/nc", args, stderr_to_stdout: true)
    assert control_status == 0

    request = %{
      "command" => "git",
      "args" => args,
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 2_000,
      "max_output_bytes" => 1_024,
      "network" => false,
      "command_class" => "git",
      "mutation" => "read"
    }

    assert {:ok, %{"status" => "nonzero", "exit_status" => 1}, evidence} =
             Jido.Console.Coding.Local.Adapter.execute(nil, request,
               workspace: workspace,
               environment_contract: environment_contract(root),
               network_allowlist: [%{host: "192.0.2.1", port: :any}],
               executables: %{
                 "git" => "/usr/bin/nc",
                 "sandbox-exec" => "/usr/bin/sandbox-exec"
               }
             )

    assert evidence.network == :disabled
  end

  test "rejects an unbounded workspace checkpoint", %{root: root} do
    large = :binary.copy(<<0>>, 17 * 1_024 * 1_024)
    File.write!(Path.join(root, "large.bin"), large)

    workspace = Workspace.new!(root: root, access: [:read, :write])
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    assert {:error, :checkpoint_size_limit_exceeded} =
             Jido.Console.Coding.Local.MutationBackend.checkpoint(workspace,
               state: state,
               profile_digest: "sha256:test"
             )
  end

  test "checks file size before reading", %{root: root} do
    File.write!(Path.join(root, "large.txt"), "too large")
    workspace = Workspace.new!(root: root, access: [:read], limits: %{max_file_bytes: 4})

    assert {:error, :file_too_large} =
             Jido.Console.Coding.Local.MutationBackend.inspect_file(workspace, "large.txt", [])
  end

  test "inspects existing, missing, and nonregular file states", %{root: root} do
    workspace = Workspace.new!(root: root, access: [:read])

    assert {:ok, state, evidence} = MutationBackend.inspect_file(workspace, "lib/value.ex", [])
    assert state.exists?
    assert state.content =~ "defmodule Value"
    assert state.size == byte_size(state.content)
    assert state.sha256 =~ "sha256:"
    assert evidence.facts["operation"] == "read"

    assert {:ok, %{exists?: false, content: nil, sha256: nil, size: 0}, _evidence} =
             MutationBackend.inspect_file(workspace, "missing.ex", [])

    assert {:error, :not_regular_file} = MutationBackend.inspect_file(workspace, "lib", [])
  end

  test "creates new files atomically and rejects a directory replacement", %{root: root} do
    workspace = Workspace.new!(root: root, access: [:read, :write])
    created = Path.join(root, "nested/new.txt")

    assert {:ok, %{method: :atomic_replace, final_state: final_state}, evidence} =
             MutationBackend.replace_file(workspace, "nested/new.txt", "new content", [])

    assert File.read!(created) == "new content"
    assert final_state.content == "new content"
    assert final_state.exists?
    assert evidence.facts["operation"] == "write"
    assert Path.wildcard(created <> ".jido-*") == []

    assert {:error, :not_regular_file} =
             MutationBackend.replace_file(workspace, "lib", "replacement", [])
  end

  test "atomic replacement preserves file mode and removes its temporary file", %{root: root} do
    path = Path.join(root, "script")
    File.write!(path, "old")
    File.chmod!(path, 0o751)
    workspace = Workspace.new!(root: root, access: [:read, :write])

    assert {:ok, %{method: :atomic_replace}, _evidence} =
             Jido.Console.Coding.Local.MutationBackend.replace_file(workspace, "script", "new", [])

    assert File.read!(path) == "new"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o751
    assert Path.wildcard(path <> ".jido-*") == []
  end

  test "checkpoint restore replaces content, restores mode, and removes created files", %{root: root} do
    path = Path.join(root, "lib/value.ex")
    File.chmod!(path, 0o640)
    workspace = Workspace.new!(root: root, access: [:read, :write])
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    opts = [state: state, profile_digest: "sha256:" <> String.duplicate("a", 64)]

    assert {:ok, checkpoint, _evidence} =
             Jido.Console.Coding.Local.MutationBackend.checkpoint(workspace, opts)

    File.write!(path, "changed")
    File.chmod!(path, 0o777)
    created = Path.join(root, "created.txt")
    File.write!(created, "created")

    assert {:ok, _evidence} =
             Jido.Console.Coding.Local.MutationBackend.restore(workspace, checkpoint, opts)

    assert File.read!(path) =~ "defmodule Value"
    refute File.exists?(created)
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o640
  end

  test "checkpoint restore rejects a file-to-directory conflict", %{root: root} do
    path = Path.join(root, "conflict")
    File.write!(path, "original")
    workspace = Workspace.new!(root: root, access: [:read, :write])
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    opts = [state: state, profile_digest: "sha256:" <> String.duplicate("c", 64)]

    assert {:ok, checkpoint, _evidence} = MutationBackend.checkpoint(workspace, opts)
    File.rm!(path)
    File.mkdir!(path)
    File.write!(Path.join(path, "created"), "new")

    assert {:error, reason} = MutationBackend.restore(workspace, checkpoint, opts)
    assert reason in [:eisdir, :eexist]
    assert File.dir?(path)
  end

  test "checkpoint skips ignored and nonregular paths and rejects an unknown reference", %{root: root} do
    ignored = Path.join(root, "ignored.txt")
    target = Path.join(root, "target.txt")
    link = Path.join(root, "linked.txt")
    File.write!(Path.join(root, ".gitignore"), "ignored.txt\n")
    File.write!(ignored, "before")
    File.write!(target, "target")
    File.ln_s!(target, link)

    workspace = Workspace.new!(root: root, access: [:read, :write])
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    opts = [state: state, profile_digest: "sha256:" <> String.duplicate("b", 64)]

    assert {:ok, checkpoint, _evidence} = MutationBackend.checkpoint(workspace, opts)
    File.write!(ignored, "after")

    assert {:ok, _evidence} = MutationBackend.restore(workspace, checkpoint, opts)
    assert File.read!(ignored) == "after"
    assert {:ok, %{type: :symlink}} = File.lstat(link)

    missing = %{checkpoint | checkpoint_ref: "local-checkpoint-missing"}
    assert {:error, :checkpoint_not_found} = MutationBackend.restore(workspace, missing, opts)
  end

  @tag :darwin
  test "constrains OpenAI decisions to one JSON object", %{root: root} do
    assert {:ok, setup} =
             Setup.prepare(Jido.Console.DefaultAgent,
               coding_profile: Local.profile_id(),
               project_root: root,
               model: "openai:gpt-4.1-mini"
             )

    on_exit(fn -> Setup.close(setup) end)
    opts = Jidoka.Agent.Spec.Generation.to_req_llm_opts(setup.spec.generation)

    assert opts[:temperature] == 0.0
    refute Keyword.has_key?(opts, :reasoning_effort)
    assert opts[:max_tokens] == 4_000
    assert setup.spec.instructions =~ "coding.verify"
    assert setup.spec.instructions =~ ~s({"helper_id":"mix-test"})
    assert ExtensionSetup.recover_coding_errors?(setup.extension_setup)
    assert setup.turn_opts[:max_parallel_operations] == 1
    refute Keyword.has_key?(opts, :provider_options)

    provider_options = setup.turn_opts[:llm_opts][:provider_options]
    assert is_list(provider_options)

    assert %{
             type: "json_schema",
             json_schema: %{
               name: "jidoka_decision",
               strict: false,
               schema: %{required: required}
             }
           } =
             provider_options[:response_format]

    assert required == ["type"]
  end

  defp environment_contract(root) do
    assert {:ok, contract} =
             Jido.Console.Coding.Environment.resolve("coding.restricted",
               jido_home: Path.join(root, "home")
             )

    contract
  end
end
