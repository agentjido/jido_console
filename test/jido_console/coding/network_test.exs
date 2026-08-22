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

    assert {:error, {:network_denied, abbreviated}} = Network.check("127.1", [])
    assert abbreviated.class == :loopback
    assert {:error, {:network_denied, _short}} = Network.check("127.0.1:9", [])

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

  test "malformed destination syntax does not become network authority" do
    for destination <- ["https://", "example.invalid:not-a-port"] do
      assert {:ok, decision} = Network.check(destination, [])
      assert decision.class == :none
    end

    assert {:error, {:network_denied, bracketed}} = Network.check("[::1]", [])
    assert bracketed.class == :loopback
  end

  test "does not treat timeout or port numbers as destinations" do
    assert {:error, {:network_denied, loopback}} =
             Network.admit(%{"args" => ["-w", "1", "-z", "127.0.0.1", "9"]})

    assert loopback.class == :loopback
  end

  test "parses valid host, class, wildcard, and decimal port rules into explicit forms" do
    cases = [
      {%{host: "EXAMPLE.INVALID", port: "443"}, "example.invalid:443",
       %{host: "example.invalid", class: nil, port: 443}},
      {%{"host" => "127.0.0.1", "port" => :any}, "127.0.0.1:65", %{host: "127.0.0.1", class: nil, port: :any}},
      {%{class: "loopback", port: :any}, "[::1]:9", %{host: nil, class: :loopback, port: :any}},
      {%{class: :external, port: "65"}, "192.0.2.1:65", %{host: nil, class: :external, port: 65}}
    ]

    for {entry, destination, normalized} <- cases do
      assert {:ok, %{allowlist: [^normalized]}} = Network.policy(network_allowlist: [entry])
      assert {:ok, decision} = Network.check(destination, [entry])
      assert decision.outcome == :allow
    end
  end

  test "rejects every malformed allowlist entry without returning partial rules" do
    cases = [
      {%{host: "example.invalid", port: 0}, :invalid_port},
      {%{host: "example.invalid", port: 65_536}, :invalid_port},
      {%{host: "example.invalid", port: "4x3"}, :invalid_port},
      {%{host: "example.invalid", port: nil}, :invalid_port},
      {%{host: "example.invalid"}, :port_required},
      {%{host: "bad_host.example", port: :any}, :invalid_host},
      {%{host: nil, port: :any}, :invalid_host},
      {%{host: "example.invalid", class: :external, port: 443}, :one_selector_required},
      {%{class: :unknown, port: :any}, :invalid_class},
      {%{class: nil, port: :any}, :invalid_class},
      {%{port: 443}, :selector_required},
      {"example.invalid:443", :entry_must_be_a_map}
    ]

    for {entry, reason} <- cases do
      assert {:error, {:invalid_network_allowlist, 0, ^reason}} = Network.policy(network_allowlist: [entry])
    end

    assert {:error, {:invalid_network_allowlist, 1, :invalid_port}} =
             Network.policy(
               network_allowlist: [
                 %{host: "example.invalid", port: 443},
                 %{class: :external, port: "invalid"},
                 %{host: "other.invalid", port: :any}
               ]
             )

    assert {:ok, %{allowlist: []}} = Network.policy(network_allowlist: [])

    assert {:error, {:invalid_network_allowlist, :not_a_list}} =
             Network.policy(network_allowlist: %{})

    assert {:error, {:invalid_network_allowlist, 0, :one_selector_required}} =
             Network.policy(network_allowlist: [%{"host" => "other.invalid", host: "example.invalid", port: 443}])

    assert {:error, {:invalid_network_allowlist, 0, :invalid_port}} =
             Network.policy(network_allowlist: [%{"port" => 8443, host: "example.invalid", port: 443}])
  end

  test "keeps normalized allowlist selectors out of evidence" do
    allowlist = [%{host: "private.example", port: :any}]
    assert {:ok, decision} = Network.check("private.example:443", allowlist)
    evidence = Network.evidence(decision)
    assert evidence["allowlist_entries"] == 1
    refute inspect(evidence) =~ "private.example"
  end

  test "adapter rejects an invalid allowlist before it starts execution" do
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

    invalid = [
      %{host: "example.invalid", port: 0},
      %{host: "example.invalid", port: 65_536},
      %{host: "example.invalid", port: "invalid"},
      %{host: "example.invalid"},
      %{port: :any},
      "example.invalid"
    ]

    for entry <- invalid do
      assert {:error, {:invalid_network_allowlist, 0, _reason}} =
               Adapter.execute(nil, request, network_allowlist: [entry])
    end
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
      environment_contract: environment_contract(root),
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
  test "operating-system sandbox denies implicit loopback from git" do
    root = Path.join(System.tmp_dir!(), "jido-implicit-net-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    connector = Path.join(root, "connect")
    File.write!(connector, "#!/bin/sh\nexec /usr/bin/nc -w 1 -z 127.0.0.1 9\n")
    File.chmod!(connector, 0o700)

    request = %{
      "command" => "git",
      "args" => ["status"],
      "stdin" => "",
      "cwd" => ".",
      "timeout_ms" => 2_000,
      "max_output_bytes" => 1_024,
      "network" => false,
      "command_class" => "git",
      "mutation" => "read"
    }

    assert {:ok, result, _evidence} =
             Adapter.execute(nil, request,
               workspace: Workspace.new!(root: root, access: [:shell]),
               environment_contract: environment_contract(root),
               executables: %{
                 "git" => connector,
                 "sandbox-exec" => System.find_executable("sandbox-exec")
               }
             )

    assert result["status"] in ["nonzero", "error"]
    refute result["status"] == "ok"
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

  defp environment_contract(root) do
    assert {:ok, contract} =
             Jido.Console.Coding.Environment.resolve("coding.restricted",
               jido_home: Path.join(root, "home")
             )

    contract
  end
end
