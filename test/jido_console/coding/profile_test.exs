defmodule Jido.Console.Coding.ProfileTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Profile
  alias Jidoka.ExecutionEnvironment.RestrictedContract

  setup do
    root = Path.join(System.tmp_dir!(), "jido-profile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [jido_home: Path.join(root, "home"), project_root: root]}
  end

  test "defaults to restricted execution without an explicit profile", %{opts: opts} do
    assert {:ok, profile} = Profile.resolve(Profile.restricted_id(), opts)
    assert profile.class == :restricted
    assert profile.sandbox? == false
    assert profile.enforcement == :pending
    refute Profile.restricted_passed?(profile)
    assert profile.environment_contract.allowlist != []
    assert profile.roots["home"] == profile.environment_contract.home
    assert profile.roots["temporary"] == profile.environment_contract.tmpdir
    assert Map.has_key?(profile.roots, "workspace")
    assert Map.has_key?(profile.roots, "toolchain")
    assert Map.has_key?(profile.roots, "artifact")
    assert Map.has_key?(profile.roots, "temporary")
  end

  test "requires an explicit choice for trusted-workspace mode", %{opts: opts} do
    assert {:error, {:explicit_profile_required, "coding.local"}} =
             Profile.resolve("coding.local", opts)

    assert {:ok, trusted} = Profile.resolve("coding.local", opts ++ [coding_profile: "coding.local"])
    assert trusted.class == :trusted_workspace
    assert trusted.warning == Profile.trusted_warning()
    assert trusted.warning =~ "not a sandbox"
    assert trusted.explicit?

    assert {:error, {:explicit_profile_required, "coding.trusted-workspace"}} =
             Profile.resolve("coding.trusted-workspace", opts ++ [coding_profile: Profile.restricted_id()])

    assert {:error, {:unknown_execution_profile, "missing"}} =
             Profile.resolve("missing", opts ++ [coding_profile: "missing"])
  end

  test "restricted profile is compatible with the Jidoka contract shape", %{opts: opts} do
    assert {:ok, profile} = Profile.resolve(Profile.restricted_id(), opts)
    assert :ok = Jidoka.ExecutionEnvironment.Contract.validate_safe_map(Profile.to_map(profile))
    digest = Jidoka.ExecutionEnvironment.digest(profile.roots)

    assert {:ok, contract} =
             RestrictedContract.new(
               profile_id: profile.id,
               roots:
                 Enum.map(RestrictedContract.root_kinds(), fn kind ->
                   %{kind: kind, digest: digest, writable: kind != :toolchain}
                 end),
               environment: %{
                 allowlist: profile.environment_contract.allowlist,
                 private_home: true
               },
               cancellation: %{enabled: true},
               deadline_ms: 30_000,
               cleanup: %{status: :clean, child_processes: 0}
             )

    assert :ok = RestrictedContract.compatible?(contract)
  end
end
