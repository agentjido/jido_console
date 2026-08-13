defmodule Jido.Cli.LocalCodingTest do
  use ExUnit.Case, async: false

  alias Jido.Cli.{CodingSetup, LocalCoding}
  alias Jidoka.CodingPack.{Edit, Verify, Workspace}

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

  test "requires an explicit root and keeps the default profile read-only", %{root: root} do
    assert {:error, :local_coding_root_required} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent, coding_profile: LocalCoding.profile_id())

    assert {:ok, setup} = CodingSetup.prepare(Jido.Cli.DefaultAgent, project_root: root)
    assert setup.workspace.access == [:read]
    assert setup.local_resources == nil
  end

  test "edits and verifies only through the trusted local ports", %{root: root} do
    workspace =
      Workspace.new!(
        root: root,
        access: [:read, :write, :shell, :git, :verify],
        limits: %{max_shell_timeout_ms: 120_000},
        execution_profile: LocalCoding.profile_id()
      )

    assert {:ok, local} = LocalCoding.prepare(workspace)
    on_exit(fn -> LocalCoding.close(local.resources) end)

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

  test "does not expose the general shell tool", %{root: root} do
    assert {:ok, setup} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent,
               coding_profile: LocalCoding.profile_id(),
               project_root: root
             )

    on_exit(fn -> CodingSetup.close(setup) end)
    {:ok, session} = Jidoka.Session.Data.start(setup.spec, session_id: "local-tool-list")
    request = Enum.find(setup.spec.extensions, &(&1.id == "jido.coding_pack"))
    {:ok, host} = Jidoka.Extension.Host.open(session, [request], setup.extension_setup.registry, :interactive)
    {:ok, compiled} = Jidoka.Operation.Source.compile(Jidoka.Extension.Host.operation_sources(host))
    names = Enum.map(compiled.operations, & &1.name)

    assert "coding.edit" in names
    assert "coding.verify" in names
    refute "coding.shell" in names
    Jidoka.Extension.Host.close(host)
  end

  test "stops local resources when later setup fails", %{root: root} do
    {:links, before_links} = Process.info(self(), :links)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_entries_invalid}} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent,
               coding_profile: LocalCoding.profile_id(),
               project_root: root,
               coding_replace_tools: "invalid"
             )

    {:links, after_links} = Process.info(self(), :links)
    assert MapSet.new(after_links) == MapSet.new(before_links)
  end

  test "stops a command when streamed output reaches its limit", %{root: root} do
    workspace =
      Workspace.new!(
        root: root,
        access: [:shell],
        execution_profile: LocalCoding.profile_id()
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
             Jido.Cli.LocalCoding.Adapter.execute(nil, request,
               workspace: workspace,
               executables: %{"git" => System.find_executable("yes")}
             )

    assert result["status"] == "error"
    assert result["exit_status"] == nil
    assert result["stdout_truncated"]
    assert byte_size(result["stdout"]) <= 1_024

    Process.sleep(20)
    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, fn message -> match?({port, _data} when is_port(port), message) end)
  end

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
             Jido.Cli.LocalCoding.Adapter.execute(nil, request,
               workspace: workspace,
               executables: %{"git" => executable}
             )

    command_pid = pid_file |> File.read!() |> String.trim()
    Process.sleep(20)
    {_output, status} = System.cmd("/bin/kill", ["-0", command_pid], stderr_to_stdout: true)
    refute status == 0
  end

  test "rejects an unbounded workspace checkpoint", %{root: root} do
    large = :binary.copy(<<0>>, 17 * 1_024 * 1_024)
    File.write!(Path.join(root, "large.bin"), large)

    workspace = Workspace.new!(root: root, access: [:read, :write])
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    assert {:error, :checkpoint_size_limit_exceeded} =
             Jido.Cli.LocalCoding.MutationBackend.checkpoint(workspace,
               state: state,
               profile_digest: "sha256:test"
             )
  end

  test "constrains OpenAI decisions to one JSON object", %{root: root} do
    assert {:ok, setup} =
             CodingSetup.prepare(Jido.Cli.DefaultAgent,
               coding_profile: LocalCoding.profile_id(),
               project_root: root,
               model: "openai:gpt-4.1-mini"
             )

    on_exit(fn -> CodingSetup.close(setup) end)
    opts = Jidoka.Agent.Spec.Generation.to_req_llm_opts(setup.spec.generation)

    assert opts[:temperature] == 0.0
    refute Keyword.has_key?(opts, :reasoning_effort)
    assert opts[:max_tokens] == 4_000
    assert setup.spec.instructions =~ "coding.verify"
    assert setup.spec.instructions =~ ~s({"helper_id":"mix-test"})
    assert setup.extension_setup.recover_coding_errors
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
end
