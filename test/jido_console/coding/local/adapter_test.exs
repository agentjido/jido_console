defmodule Jido.Console.Coding.Local.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Environment.Contract
  alias Jido.Console.Coding.Local
  alias Jido.Console.Coding.Local.Adapter
  alias Jidoka.CodingPack.Workspace
  alias Jidoka.ExecutionEnvironment.SecurityProfile

  setup do
    root = Path.join(System.tmp_dir!(), "jido-local-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    contract = %Contract{
      profile_id: Local.profile_id(),
      allowlist: [],
      credential_refs: [],
      home: Path.join(root, "home"),
      tmpdir: Path.join(root, "tmp")
    }

    workspace = Workspace.new!(root: root, access: [:shell])

    profile =
      SecurityProfile.new!(
        profile_id: contract.profile_id,
        revision: 1,
        digest: "sha256:" <> String.duplicate("a", 64),
        adapter_id: "jido_console.local_folder",
        required_isolation: :process,
        required_network: :disabled,
        required_workspace: :persistent
      )

    %{contract: contract, profile: profile, root: root, workspace: workspace}
  end

  test "implements the bounded adapter lifecycle", context do
    opts = [
      environment_contract: context.contract,
      workspace: context.workspace,
      observed_at_ms: 123
    ]

    assert {:ok, binding, evidence} = Adapter.open(context.profile, nil, opts)
    assert binding.profile_id == context.profile.profile_id
    assert evidence.observed_at_ms == 123

    assert {:ok, %{resource_ref: resource_ref}, acquired} = Adapter.acquire(binding, opts)
    assert resource_ref == binding.resource_ref
    assert acquired.status == :confirmed

    assert {:error, :checkpoint_unsupported} = Adapter.checkpoint(nil, binding, opts)
    assert {:error, :restore_unsupported} = Adapter.restore(binding, nil, opts)
    assert {:error, :fork_unsupported} = Adapter.fork(binding, nil, opts)
    assert {:ok, _evidence} = Adapter.close(nil, opts)
    assert {:ok, _evidence} = Adapter.cleanup(binding, opts)
    assert :ok = Local.close(nil)

    mismatch = %{context.profile | profile_id: "other"}

    assert {:error, :environment_contract_profile_mismatch} =
             Adapter.open(mismatch, nil, opts)
  end

  test "rejects malformed, unsafe, unresolved, and unavailable commands", context do
    opts = [
      environment_contract: context.contract,
      workspace: context.workspace,
      executables: %{},
      network_allowlist: []
    ]

    assert {:error, {:local_coding_request_invalid, _errors}} = Adapter.execute(nil, %{}, opts)

    assert {:error, :local_coding_request_text_invalid} =
             Adapter.execute(nil, %{request("git") | "command_class" => <<"bad", 0>>}, opts)

    assert {:error, _reason} = Adapter.execute(nil, %{request("git") | "cwd" => "../outside"}, opts)
    assert {:error, :command_unavailable} = Adapter.execute(nil, request("git"), opts)

    assert {:error, :local_coding_request_invalid} =
             Adapter.execute(nil, request("git"), Keyword.put(opts, :workspace, :invalid))
  end

  test "runs commands through an injected sandbox boundary", context do
    sandbox = fake_sandbox(context.root)

    opts = [
      environment_contract: context.contract,
      workspace: context.workspace,
      network_allowlist: []
    ]

    success_request = %{request("git") | "args" => ["hello"], "timeout_ms" => 5_000}

    assert {:ok, %{"status" => "ok", "stdout" => "hello\n", "exit_status" => 0}, evidence} =
             Adapter.execute(
               nil,
               success_request,
               Keyword.put(opts, :executables, %{
                 "git" => System.find_executable("echo"),
                 "sandbox-exec" => sandbox
               })
             )

    assert evidence.facts["shell_execute"]
    assert evidence.applied_limits["output_bytes"] == 100

    assert {:ok, %{"status" => "nonzero", "exit_status" => 1}, _evidence} =
             Adapter.execute(
               nil,
               %{request("git") | "timeout_ms" => 5_000},
               Keyword.put(opts, :executables, %{
                 "git" => System.find_executable("false"),
                 "sandbox-exec" => sandbox
               })
             )
  end

  test "bounds captured command output and wall time", context do
    sandbox = fake_sandbox(context.root)

    opts = [
      environment_contract: context.contract,
      workspace: context.workspace,
      network_allowlist: []
    ]

    output_request = %{
      request("git")
      | "args" => [String.duplicate("x", 256)],
        "max_output_bytes" => 32,
        "timeout_ms" => 5_000
    }

    assert {:ok,
            %{
              "status" => "error",
              "stdout" => output,
              "stdout_truncated" => true
            }, _evidence} =
             Adapter.execute(
               nil,
               output_request,
               Keyword.put(opts, :executables, %{
                 "git" => System.find_executable("echo"),
                 "sandbox-exec" => sandbox
               })
             )

    assert byte_size(output) == 32

    timeout_request = %{request("git") | "args" => ["1"], "timeout_ms" => 1}

    assert {:ok, %{"status" => "timeout", "exit_status" => nil}, _evidence} =
             Adapter.execute(
               nil,
               timeout_request,
               Keyword.put(opts, :executables, %{
                 "git" => System.find_executable("sleep"),
                 "sandbox-exec" => sandbox
               })
             )
  end

  defp request(command) do
    %{
      "command" => command,
      "args" => [],
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 100,
      "max_output_bytes" => 100,
      "network" => false,
      "command_class" => "test",
      "mutation" => "read"
    }
  end

  defp fake_sandbox(root) do
    path = Path.join(root, "test-sandbox")
    File.write!(path, "#!/bin/sh\nshift 2\nexec \"$@\"\n")
    File.chmod!(path, 0o700)
    path
  end
end
