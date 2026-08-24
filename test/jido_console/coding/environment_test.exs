defmodule Jido.Console.Coding.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Environment

  setup do
    root = Path.join(System.tmp_dir!(), "jido-env-iso-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [jido_home: Path.join(root, "home")]}
  end

  test "restricted env contains only allowlisted keys and a private HOME", %{opts: opts} do
    host = %{
      "PATH" => "/bin",
      "LANG" => "C",
      "SECRET" => "should-not-pass",
      "OPENAI_API_KEY" => "sk-secret",
      "HOME" => System.user_home!()
    }

    assert {:ok, contract} =
             Environment.resolve(
               "coding.restricted",
               opts ++
                 [
                   environment_allowlist: ["PATH", "LANG", "HOME", "TMPDIR"]
                 ]
             )

    assert {:ok, env} = Environment.materialize(contract, host_env: host)
    assert Map.keys(env) |> Enum.sort() == ["HOME", "LANG", "PATH", "TMPDIR"]
    refute env["HOME"] == System.user_home!()
    assert env["HOME"] == contract.home
    assert env["TMPDIR"] == contract.tmpdir
    refute Map.has_key?(env, "SECRET")
    refute Map.has_key?(env, "OPENAI_API_KEY")

    evidence = Environment.evidence(contract)
    assert evidence["execution_policy_id"] == "coding.restricted"
    refute Map.has_key?(evidence, "profile_id")
    assert evidence["home"] == "private"
    assert evidence["tmpdir"] == "declared"
    assert evidence["references"] == []
    assert evidence["contract_digest"] == Environment.digest(contract)
    refute inspect(contract) =~ "sk-secret"
    refute inspect(evidence) =~ contract.home
    refute inspect(evidence) =~ System.user_home!()
  end

  test "rejects undeclared credential sources and incomplete contracts", %{opts: opts} do
    assert {:error, {:undeclared_credential_source, ["CUSTOM_SECRET"]}} =
             Environment.resolve("coding.restricted", opts ++ [credential_sources: ["CUSTOM_SECRET"]])

    assert {:error, :incomplete_environment_contract} =
             Environment.resolve("coding.restricted", opts ++ [environment_allowlist: []])

    assert {:error, :invalid_environment_allowlist} =
             Environment.resolve("coding.restricted", opts ++ [environment_allowlist: [""]])

    assert {:error, {:credential_in_environment_allowlist, ["OPENAI_API_KEY"]}} =
             Environment.resolve(
               "coding.restricted",
               opts ++ [environment_allowlist: ["PATH", "OPENAI_API_KEY"]]
             )

    assert {:error, :invalid_credential_sources} =
             Environment.resolve("coding.restricted", opts ++ [credential_sources: "OPENAI_API_KEY"])
  end

  test "declared credentials stay as references until materialization", %{opts: opts} do
    assert {:ok, contract} =
             Environment.resolve(
               "coding.restricted",
               opts ++ [credential_sources: ["OPENAI_API_KEY"]]
             )

    assert contract.credential_refs == ["env:OPENAI_API_KEY"]
    refute inspect(contract) =~ "sk-secret"

    assert {:ok, env} =
             Environment.materialize(contract,
               host_env: %{"PATH" => "/bin", "OPENAI_API_KEY" => "sk-secret"}
             )

    assert env["OPENAI_API_KEY"] == "sk-secret"
    evidence = Environment.evidence(contract)
    assert evidence["references"] == ["env:OPENAI_API_KEY"]
    refute inspect(evidence) =~ "sk-secret"
    assert :ok = Jidoka.ExecutionEnvironment.Contract.validate_safe_map(evidence)
  end

  test "normalizes the legacy local policy ID in the canonical contract", %{opts: opts} do
    assert {:ok, contract} = Environment.resolve("coding.local", opts)
    assert contract.execution_policy_id == "coding.trusted-workspace"
    refute Map.has_key?(Map.from_struct(contract), :profile_id)
  end

  test "accepts broader provider variables loaded by Env", %{opts: opts} do
    assert {:ok, contract} =
             Environment.resolve(
               "coding.restricted",
               opts ++ [credential_sources: ["GROQ_API_KEY", "XAI_API_KEY"]]
             )

    assert contract.credential_refs == ["env:GROQ_API_KEY", "env:XAI_API_KEY"]
  end
end
