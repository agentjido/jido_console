defmodule Jido.Console.Coding.ProfileTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Coding.Profile
  alias Jidoka.ExecutionEnvironment.RestrictedContract

  setup do
    root = Path.join(System.tmp_dir!(), "jido-profile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [jido_home: Path.join(root, "home"), project_root: root]}
  end

  test "compatibility facade defaults to restricted execution", %{opts: opts} do
    assert {:ok, profile} = Profile.resolve(Profile.restricted_id(), opts)
    assert profile.class == :restricted
    assert profile.execution_policy_id == "coding.restricted"
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
    assert {:error, {:consent_required, "coding.trusted-workspace"}} =
             Profile.resolve("coding.local", opts)

    assert {:ok, trusted} = Profile.resolve("coding.local", opts ++ [coding_profile: "coding.local"])
    assert trusted.class == :trusted_workspace
    assert trusted.id == "coding.trusted-workspace"
    assert trusted.environment_contract.execution_policy_id == "coding.trusted-workspace"
    assert trusted.warning == Profile.trusted_warning()
    assert trusted.warning =~ "not a sandbox"
    assert trusted.explicit?

    assert {:error, {:execution_policy_mismatch, "coding.trusted-workspace", "coding.restricted"}} =
             Profile.resolve("coding.trusted-workspace", opts ++ [coding_profile: Profile.restricted_id()])

    assert {:error, {:unknown_execution_policy, "missing"}} =
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

  test "exposes trusted and disabled profile projections", %{opts: opts} do
    assert Profile.trusted_id() == "coding.trusted-workspace"
    assert Profile.restricted_passed?(%{class: :restricted, enforcement: :reported})

    assert {:ok, disabled} = Profile.resolve(nil, opts)
    assert Profile.to_map(disabled)["environment"] == %{}
    assert Profile.to_map(disabled)["execution_policy_id"] == nil
  end

  test "treats an application-level legacy value only as a proposal", %{opts: opts} do
    previous = Application.get_env(:jido_console, :coding_profile)
    Application.put_env(:jido_console, :coding_profile, "coding.local")

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:jido_console, :coding_profile),
        else: Application.put_env(:jido_console, :coding_profile, previous)
    end)

    refute Profile.explicit_choice?([])

    assert {:error, {:consent_required, "coding.trusted-workspace"}} =
             Profile.resolve("coding.local", opts)
  end

  test "facade functions expose only the planned deprecation notice" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Profile)

    notices =
      docs
      |> Enum.flat_map(fn
        {{:function, _name, _arity}, _, _, _, %{deprecated: notice}} -> [notice]
        _entry -> []
      end)
      |> Enum.uniq()

    assert notices == ["Use Jido.Console.ExecutionPolicy"]
  end
end
