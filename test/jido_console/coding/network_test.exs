defmodule Jido.Console.Coding.NetworkTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Local.Adapter
  alias Jido.Console.Coding.Network
  alias Jido.Console.Release.Boundaries
  alias Jidoka.CodingPack.Workspace

  test "denies undeclared loopback and external destinations before a connect" do
    assert {:error, {:network_denied, loopback}} = Network.check("127.0.0.1", [])
    assert loopback.outcome == :deny
    assert loopback.class == :loopback
    assert loopback.policy.version == "1"
    refute loopback.reason =~ "127.0.0.1"

    assert {:error, {:network_denied, external}} = Network.check("192.0.2.1", [])
    assert external.outcome == :deny
    assert external.class == :external

    assert {:error, {:network_denied, named}} = Network.check("github.com", [])
    assert named.class == :external
    refute inspect(Network.evidence(external)) =~ "192.0.2.1"
  end

  test "allows a declared destination and denies offline use" do
    allowlist = [%{host: "127.0.0.1", port: 9}]

    assert {:ok, allowed} = Network.check("127.0.0.1:9", allowlist)
    assert allowed.outcome == :allow
    assert allowed.class == :loopback

    assert {:error, {:network_denied, offline}} =
             Network.admit(%{"args" => ["https://example.invalid/v1"]}, offline: true)

    assert offline.outcome == :deny
    assert offline.policy.mode == :offline
    refute offline.reason =~ "example.invalid"
  end

  test "preserves URI ports and IPv6 host-port pairs" do
    allowlist = [%{host: "example.invalid", port: 443}]

    assert {:ok, allowed} = Network.check("https://example.invalid:443/v1", allowlist)
    assert allowed.outcome == :allow

    assert {:error, {:network_denied, _denied}} = Network.check("https://example.invalid:8443/v1", allowlist)

    assert {:ok, loopback} = Network.check("[::1]:9", [%{host: "::1", port: 9}])
    assert loopback.class == :loopback
    assert {:error, {:network_denied, _miss}} = Network.check("[::1]:9", [])
  end

  test "commands without destinations stay allowed" do
    assert {:ok, decision} = Network.admit(%{"args" => ["status", "--short"]})
    assert decision.outcome == :allow
    assert decision.class == :none

    assert {:ok, files} = Network.admit(%{"args" => ["add", "lib/value.ex", "README.md"]})
    assert files.outcome == :allow
  end

  test "does not treat timeout or port numbers as destinations" do
    assert {:error, {:network_denied, loopback}} =
             Network.admit(%{"args" => ["-w", "1", "-z", "127.0.0.1", "9"]})

    assert loopback.class == :loopback
  end

  test "adapter denies undeclared destinations without reaching the endpoint" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    acceptor =
      Task.async(fn ->
        accepted? =
          case :gen_tcp.accept(listener, 500) do
            {:ok, socket} ->
              :gen_tcp.close(socket)
              true

            {:error, _reason} ->
              false
          end

        send(parent, {:accepted, accepted?})
      end)

    root = Path.join(System.tmp_dir!(), "jido-network-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    request = %{
      "command" => "git",
      "args" => ["-w", "1", "-z", "127.0.0.1", Integer.to_string(port)],
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 1_000,
      "max_output_bytes" => 1_024,
      "network" => false,
      "command_class" => "git",
      "mutation" => "read"
    }

    opts = [
      workspace: Workspace.new!(root: root, access: [:shell]),
      executables: %{"git" => System.find_executable("nc") || "nc"}
    ]

    assert {:error, {:network_denied, decision}} = Adapter.execute(nil, request, opts)
    assert decision.class == :loopback

    accepted? =
      receive do
        {:accepted, value} -> value
      after
        1_000 -> true
      end

    :gen_tcp.close(listener)
    Task.shutdown(acceptor, :brutal_kill)
    refute accepted?
  end

  @tag :darwin
  test "Gate 0 hostile runtime-boundary network fixtures are denied" do
    result =
      Boundaries.runtime_boundary!(
        process_probe: fn ->
          Enum.map(~w(success rejection cancellation timeout owner_exit), fn name ->
            %{"name" => name, "classification" => "denied", "runner_cleanup" => "passed"}
          end)
        end
      )

    assert result["status"] == "passed"
    assert result["public_endpoints_contacted"] == 0
    assert Enum.map(result["network"], & &1["classification"]) == ["denied", "denied"]
    refute inspect(result) =~ "sk-"
  end
end
