defmodule Jido.Console.ExecutionPolicy.RegistryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.{Record, Registry}

  alias Jidoka.ExecutionEnvironment.{
    AdapterCapabilities,
    PolicyRequest,
    Registration,
    SecurityProfile,
    Selection
  }

  test "builds host-owned records through the public Jidoka contracts" do
    registry = Registry.new!()

    for id <- [ExecutionPolicy.restricted_id(), ExecutionPolicy.trusted_id()] do
      assert {:ok,
              %Record{
                execution_policy_id: ^id,
                policy_request: %PolicyRequest{},
                security_profile: %SecurityProfile{},
                adapter_capabilities: %AdapterCapabilities{},
                registration: %Registration{},
                jidoka_selection: %Selection{}
              } = record} = Registry.fetch(registry, id)

      assert {:ok, ^record} = Registry.fetch(registry, id)
      assert record.policy_request.profile_id == id
      assert record.security_profile.profile_id == id
      assert record.registration.profile == record.security_profile
      assert record.registration.capabilities == record.adapter_capabilities
      assert {:ok, ^record} = Record.validate(record)
    end
  end

  test "normalizes aliases before registry lookup and evidence" do
    registry = Registry.new!()

    assert {:ok, canonical} = Registry.fetch(registry, "coding.trusted-workspace")
    assert {:ok, alias_record} = Registry.fetch(registry, "coding.local")
    assert canonical == alias_record
    assert Record.evidence(alias_record)["execution_policy_id"] == "coding.trusted-workspace"
  end

  test "policy evidence changes with every security-relevant registry input" do
    base = trusted_evidence([])

    refute trusted_evidence(profile_revision: 2) == base
    refute trusted_evidence(adapter_version: "2") == base
    refute trusted_evidence(capability_ids: ["shell.execute", "files.read"]) == base

    refute trusted_evidence(maximum_limits: %{"wall_time_ms" => 60_000, "output_bytes" => 262_144}) ==
             base
  end

  test "rejects an unknown policy without calling an external resolver" do
    registry = Registry.new!()
    assert {:error, {:unknown_execution_policy, "missing"}} = Registry.fetch(registry, "missing")
  end

  defp trusted_evidence(opts) do
    opts
    |> Registry.new!()
    |> Registry.fetch!(ExecutionPolicy.trusted_id())
    |> Record.evidence()
  end
end
