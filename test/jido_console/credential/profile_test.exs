defmodule Jido.Console.Credential.ProfileTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Credential.Profile
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor

  @canary "CREDENTIAL_CANARY_DO_NOT_STORE"

  setup do
    root = Path.join(System.tmp_dir!(), "jido-credential-profile-#{System.unique_integer([:positive])}")

    names = [
      name: unique(:supervisor),
      lock: unique(:lock),
      maintenance: unique(:maintenance),
      quota: unique(:quota),
      admission: unique(:admission),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(names)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, names: names, supervisor: supervisor}
  end

  test "stores immutable versions below an isolated Jido home and restores them", context do
    opts = storage_opts(context.names, "profile-create")
    assert {:ok, %{profile_version: 1, duplicate: false}} = Profile.create(profile(), opts)

    assert {:ok, shown} = Profile.show("provider-main", opts)
    assert shown.profile_version == 1
    assert shown.references |> hd() |> Map.keys() |> Enum.sort() == [:disabled, :kind, :reference_id, :source_identity]
    refute inspect(shown) =~ "OPENAI_API_KEY"

    assert {:ok, [listed]} = Profile.list(opts)
    assert listed == shown

    Supervisor.stop(context.supervisor)
    assert {:ok, _restarted} = StorageSupervisor.start_link(context.names)
    assert {:ok, ^shown} = Profile.show("provider-main", storage_opts(context.names, "read-after-restart"))

    database = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    assert File.regular?(database)
    assert String.starts_with?(database, Path.join(context.root, "state") <> "/")

    context.root
    |> Path.join("state/sessions/v1/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.each(fn path -> refute File.read!(path) =~ @canary end)
  end

  test "keeps reference identity stable and resolves an exact selection without fallback", context do
    opts = storage_opts(context.names, "profile-create")
    assert {:ok, _created} = Profile.create(profile(), opts)
    assert {:ok, selection} = Profile.select("provider-main", Keyword.put(opts, :reference_id, "host-openai"))

    test_pid = self()

    assert {:ok, :called} =
             Profile.materialize(
               selection,
               fn value ->
                 send(test_pid, {:materialized, value})
                 :called
               end,
               Keyword.merge(opts, boundary: :provider, host_env: %{"OPENAI_API_KEY" => "first-value"})
             )

    assert_receive {:materialized, "first-value"}

    assert {:ok, :called} =
             Profile.materialize(
               selection,
               fn value ->
                 send(test_pid, {:rotated, value})
                 :called
               end,
               Keyword.merge(opts, boundary: :provider, host_env: %{"OPENAI_API_KEY" => "rotated-value"})
             )

    assert_receive {:rotated, "rotated-value"}

    assert {:error, {:credential_source_missing, %{}}} =
             Profile.materialize(
               selection,
               fn _value -> flunk("must not call boundary") end,
               Keyword.merge(opts,
                 boundary: :provider,
                 host_env: %{"ANTHROPIC_API_KEY" => "fallback-must-not-run"}
               )
             )
             |> redact_reference_error()
  end

  test "adds versions, rejects identity changes, and applies later disable state", context do
    opts = storage_opts(context.names, "profile-create")
    assert {:ok, _created} = Profile.create(profile(), opts)
    assert {:ok, selection} = Profile.select("provider-main", Keyword.put(opts, :reference_id, "host-openai"))

    version_two =
      profile()
      |> Map.put("profile_version", 2)
      |> put_in(["references", Access.at(1), "disabled"], true)

    assert {:ok, %{profile_version: 2}} =
             Profile.new_version(version_two, storage_opts(context.names, "profile-v2"))

    changed = put_in(version_two, ["references", Access.at(0), "lookup", "name"], "OTHER_API_KEY")
    changed = Map.put(changed, "profile_version", 3)

    assert {:error, :credential_reference_identity_changed} =
             Profile.new_version(changed, storage_opts(context.names, "profile-changed"))

    removed =
      version_two
      |> Map.put("profile_version", 3)
      |> Map.put("references", [hd(version_two["references"])])

    assert {:error, {:credential_reference_removed, ["host-anthropic"]}} =
             Profile.new_version(removed, storage_opts(context.names, "profile-removed"))

    assert {:ok, %{status: :compatible}} = Profile.compatibility(selection, opts)

    assert {:error, {:credential_source_identity_changed, "host-openai"}} =
             Profile.compatibility(%{selection | source_identity: "changed-host"}, opts)

    assert {:ok, %{profile_version: 3}} =
             Profile.disable_reference(
               "provider-main",
               "host-openai",
               storage_opts(context.names, "reference-disable")
             )

    assert {:error, {:credential_reference_disabled, "host-openai"}} = Profile.compatibility(selection, opts)

    assert {:ok, %{duplicate: true}} =
             Profile.disable_reference(
               "provider-main",
               "host-openai",
               storage_opts(context.names, "reference-disable-repeat")
             )

    assert {:ok, %{profile_version: 4, disabled: true}} =
             Profile.disable("provider-main", storage_opts(context.names, "profile-disable"))

    assert {:error, {:credential_profile_disabled, "provider-main", 4}} = Profile.compatibility(selection, opts)

    assert {:ok, %{duplicate: true}} =
             Profile.disable("provider-main", storage_opts(context.names, "profile-disable-repeat"))
  end

  test "rejects credential fields before the bounded write", context do
    candidate = Map.put(profile(), "token", @canary)

    assert {:error, {:sensitive_value_rejected, %{"redacted" => true}}} =
             Profile.create(candidate, storage_opts(context.names, "profile-sensitive"))
             |> redact_sensitive_error()

    assert {:ok, []} = Profile.list(storage_opts(context.names, "profile-list"))
  end

  test "returns typed results for invalid, missing, and incompatible profile operations", context do
    opts = storage_opts(context.names, "profile-create")

    assert {:error, :invalid_credential_profile} = Profile.create(:invalid, opts)

    assert {:error, {:credential_profile_version_conflict, 1, 2}} =
             Profile.create(Map.put(profile(), "profile_version", 2), opts)

    assert {:error, :operation_id_required} =
             Profile.create(Map.put(profile(), "profile_id", "operation-required"),
               admission: context.names[:admission],
               quota: context.names[:quota],
               writer: context.names[:writer]
             )

    assert {:ok, _created} = Profile.create(profile(), opts)
    assert {:error, {:credential_profile_exists, "provider-main"}} = Profile.create(profile(), opts)
    assert {:error, :invalid_credential_profile} = Profile.new_version(:invalid, opts)

    missing_profile =
      profile()
      |> Map.put("profile_id", "provider-missing")
      |> Map.put("profile_version", 2)

    assert {:error, {:credential_profile_not_found, "provider-missing"}} =
             Profile.new_version(missing_profile, storage_opts(context.names, "missing-version"))

    changed_source =
      profile()
      |> Map.put("profile_version", 2)
      |> Map.put("source_identity", "host-changed")
      |> Map.update!("references", fn references ->
        Enum.map(references, &Map.put(&1, "source_identity", "host-changed"))
      end)

    assert {:error, :credential_profile_identity_changed} =
             Profile.new_version(changed_source, storage_opts(context.names, "changed-source"))

    assert {:ok, %{status: :active, profile_version: 1}} = Profile.status("provider-main", opts)
    assert {:ok, %{reference_id: "host-openai"}} = Profile.select("provider-main", opts)

    assert {:error, {:credential_profile_version_not_found, "provider-main", 9}} =
             Profile.show("provider-main", 9, opts)

    assert {:error, {:credential_profile_version_not_found, "provider-main", 9}} =
             Profile.select("provider-main", Keyword.put(opts, :profile_version, 9))

    assert {:error, {:credential_reference_not_found, "provider-main", "unknown"}} =
             Profile.select("provider-main", Keyword.put(opts, :reference_id, "unknown"))

    assert {:error, :invalid_credential_reference_id} =
             Profile.select("provider-main", Keyword.put(opts, :reference_id, 42))

    assert {:error, :invalid_credential_selection} = Profile.compatibility(%{}, opts)
    assert {:error, :invalid_credential_selection} = Profile.compatibility(:invalid, opts)
    assert {:error, :invalid_credential_materialization} = Profile.materialize(:invalid, :invalid, opts)

    assert {:error, {:credential_profile_not_found, "unknown"}} = Profile.disable("unknown", opts)

    assert {:error, {:credential_reference_not_found, "provider-main", "unknown"}} =
             Profile.disable_reference("provider-main", "unknown", opts)
  end

  test "enforces the immutable version limit in the write transaction", context do
    assert {:ok, _created} = Profile.create(profile(), storage_opts(context.names, "profile-v1"))

    Enum.each(2..128, fn version ->
      candidate = Map.put(profile(), "profile_version", version)

      assert {:ok, %{profile_version: ^version}} =
               Profile.new_version(candidate, storage_opts(context.names, "profile-v#{version}"))
    end)

    candidate = Map.put(profile(), "profile_version", 129)

    assert {:error, {:credential_profile_version_limit, "credential-profile:provider-main", 128}} =
             Profile.new_version(candidate, storage_opts(context.names, "profile-v129"))

    assert {:ok, %{profile_version: 128}} = Profile.show("provider-main", storage_opts(context.names, "show-v128"))
  end

  test "enforces the total profile limit in the write transaction", context do
    Enum.each(1..128, fn index ->
      profile_id = "provider-#{index}"

      candidate =
        profile()
        |> Map.put("profile_id", profile_id)

      assert {:ok, %{profile_id: ^profile_id}} =
               Profile.create(candidate, storage_opts(context.names, "create-#{profile_id}"))
    end)

    overflow = Map.put(profile(), "profile_id", "provider-overflow")

    assert {:error, {:credential_profile_limit, 128}} =
             Profile.create(overflow, storage_opts(context.names, "create-overflow"))

    assert {:ok, profiles} = Profile.list(storage_opts(context.names, "list-bounded"))
    assert length(profiles) == 128
  end

  defp profile do
    %{
      "profile_id" => "provider-main",
      "profile_version" => 1,
      "source_identity" => "host-primary",
      "references" => [
        %{
          "reference_id" => "host-openai",
          "kind" => "environment",
          "source_identity" => "host-primary",
          "lookup" => %{"name" => "OPENAI_API_KEY"}
        },
        %{
          "reference_id" => "host-anthropic",
          "kind" => "environment",
          "source_identity" => "host-primary",
          "lookup" => %{"name" => "ANTHROPIC_API_KEY"}
        }
      ]
    }
  end

  defp storage_opts(names, operation_id) do
    [
      admission: names[:admission],
      quota: names[:quota],
      writer: names[:writer],
      operation_id: operation_id
    ]
  end

  defp redact_reference_error({:error, {kind, _reference}}), do: {:error, {kind, %{}}}
  defp redact_reference_error(other), do: other

  defp redact_sensitive_error({:error, {:sensitive_value_rejected, details}}),
    do: {:error, {:sensitive_value_rejected, Map.take(details, ["redacted"])}}

  defp redact_sensitive_error(other), do: other
  defp unique(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
