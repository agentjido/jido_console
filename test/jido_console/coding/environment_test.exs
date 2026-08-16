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

    assert {:ok, built} =
             Environment.build(
               opts ++
                 [
                   host_env: host,
                   allowlist: ["PATH", "LANG", "HOME", "TMPDIR"]
                 ]
             )

    assert Map.keys(built.env) |> Enum.sort() == ["HOME", "LANG", "PATH", "TMPDIR"]
    refute built.env["HOME"] == System.user_home!()
    assert String.contains?(built.env["HOME"], "restricted-home")
    refute Map.has_key?(built.env, "SECRET")
    refute Map.has_key?(built.env, "OPENAI_API_KEY")
    assert built.manifest.keys == ["HOME", "LANG", "PATH", "TMPDIR"]
    assert built.manifest.home == "private"
    refute inspect(built.manifest) =~ "sk-secret"
    refute inspect(built.manifest) =~ System.user_home!()
  end

  test "rejects undeclared credential sources and incomplete contracts", %{opts: opts} do
    assert {:error, {:undeclared_credential_source, ["CUSTOM_SECRET"]}} =
             Environment.build(opts ++ [credential_sources: ["CUSTOM_SECRET"]])

    assert {:error, :incomplete_environment_contract} = Environment.build(opts ++ [allowlist: []])
    assert {:error, :invalid_environment_allowlist} = Environment.build(opts ++ [allowlist: [""]])
  end

  test "declared credential sources appear only as references", %{opts: opts} do
    assert {:ok, built} =
             Environment.build(
               opts ++
                 [
                   host_env: %{"PATH" => "/bin", "OPENAI_API_KEY" => "sk-secret"},
                   credential_sources: ["OPENAI_API_KEY"]
                 ]
             )

    assert built.manifest.credential_refs == ["env:OPENAI_API_KEY"]
    refute Map.has_key?(built.env, "OPENAI_API_KEY")
    refute inspect(built) =~ "sk-secret"
  end

  test "accepts broader provider variables loaded by Env", %{opts: opts} do
    assert {:ok, built} =
             Environment.build(opts ++ [credential_sources: ["GROQ_API_KEY", "XAI_API_KEY"]])

    assert built.manifest.credential_refs == ["env:GROQ_API_KEY", "env:XAI_API_KEY"]
  end
end
