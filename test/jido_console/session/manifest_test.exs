defmodule Jido.Console.Session.ManifestTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Credential.Profile
  alias Jido.Console.Session.Durable.TurnManifest
  alias Jido.Console.Session.Manifest
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor

  @digest "sha256:" <> String.duplicate("a", 64)
  @canary "MANIFEST_CREDENTIAL_CANARY_DO_NOT_STORE"

  setup do
    root = Path.join(System.tmp_dir!(), "jido-turn-manifest-#{System.unique_integer([:positive])}")

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

  test "persists exact turn and invocation identity and restores it below Jido home", context do
    opts = storage_opts(context.names, "manifest-create")
    assert {:ok, %{manifest: stored, duplicate: false}} = Manifest.create("session-main", manifest(), opts)
    assert {:ok, %{manifest: ^stored, duplicate: true}} = Manifest.create("session-main", manifest(), opts)
    assert stored == manifest()
    assert {:ok, ^stored} = Manifest.load("session-main", "request-main", opts)

    Supervisor.stop(context.supervisor)
    assert {:ok, _restarted} = StorageSupervisor.start_link(context.names)
    assert {:ok, ^stored} = Manifest.load("session-main", "request-main", opts)

    database = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    assert File.regular?(database)
    refute File.read!(database) =~ @canary
    refute inspect(stored) =~ @canary
  end

  test "checks every exact identity and returns explicit workspace drift", context do
    opts = storage_opts(context.names, "manifest-create")
    assert {:ok, _created} = Manifest.create("session-main", manifest(), opts)

    assert {:ok, %{status: :compatible, manifest: restored}} =
             Manifest.compatibility("session-main", "request-main", current(), opts)

    assert restored == manifest()

    assert {:error, {:turn_manifest_identity_missing, "model_id", "model-main"}} =
             Manifest.compatibility("session-main", "request-main", Map.delete(current(), "model_id"), opts)

    assert {:error, {:turn_manifest_identity_incompatible, "provider_id", "provider-main", "provider-changed"}} =
             Manifest.compatibility(
               "session-main",
               "request-main",
               Map.put(current(), "provider_id", "provider-changed"),
               opts
             )

    assert {:error, {:workspace_drift, drift}} =
             Manifest.compatibility(
               "session-main",
               "request-main",
               Map.put(current(), "workspace_digest", digest("b")),
               opts
             )

    assert drift.accepted_digest == @digest
    assert drift.current_digest == digest("b")
  end

  test "checks only the recorded credential reference without resolving a value", context do
    profile_opts = storage_opts(context.names, "profile-create")
    assert {:ok, _created} = Profile.create(profile(), profile_opts)

    assert {:ok, _manifest} =
             Manifest.create("session-main", credential_manifest(), storage_opts(context.names, "manifest"))

    assert {:ok, %{status: :compatible}} =
             Manifest.compatibility("session-main", "request-main", current(), profile_opts)

    assert {:ok, _disabled} =
             Profile.disable_reference("provider-credentials", "host-openai", storage_opts(context.names, "disable"))

    assert {:error, {:credential_reference_disabled, "host-openai"}} =
             Manifest.compatibility("session-main", "request-main", current(), profile_opts)
  end

  test "rejects incomplete identity, credential values, and mutation", context do
    opts = storage_opts(context.names, "manifest-create")

    assert {:error, {:missing_record_payload_fields, ["variant_id"]}} =
             Manifest.create("session-main", Map.delete(manifest(), "variant_id"), opts)

    assert {:error, {:sensitive_value_rejected, %{"redacted" => true}}} =
             Manifest.create("session-main", Map.put(manifest(), "api_key", @canary), opts)
             |> redact_sensitive_error()

    assert {:error, {:forbidden_audit_value, %{"redacted" => true}}} =
             Manifest.create(
               "session-main",
               Map.put(manifest(), "provider_id", @canary),
               Keyword.put(opts, :forbidden_values, [@canary])
             )
             |> redact_forbidden_error()

    assert {:ok, _created} = Manifest.create("session-main", manifest(), opts)

    assert {:error, {:turn_manifest_exists, "session-main", "request-main"}} =
             Manifest.create(
               "session-main",
               Map.put(manifest(), "model_id", "changed"),
               storage_opts(context.names, "manifest-change")
             )
  end

  test "creates stable portable identities and rejects runtime values" do
    assert {:ok, first} = Manifest.identity(%{"temperature" => 0.2, "tools" => ["read"]})
    assert {:ok, ^first} = Manifest.identity(%{"tools" => ["read"], "temperature" => 0.2})
    assert {:error, {:sensitive_value_rejected, _redacted}} = Manifest.identity(%{"token" => @canary})
    assert {:error, {:sensitive_value_rejected, _redacted}} = Manifest.identity(self())
  end

  test "returns typed results for invalid scopes, missing records, and missing current identity", context do
    opts = storage_opts(context.names, "manifest-create")

    assert {:error, :invalid_turn_manifest} = Manifest.create(:invalid, :invalid, opts)
    assert {:error, :invalid_turn_manifest_scope} = Manifest.create("invalid scope", manifest(), opts)

    assert {:error, :invalid_turn_manifest_scope} =
             Manifest.create("session-main", Map.put(manifest(), "request_id", %{}), opts)

    assert {:error, :invalid_turn_manifest_scope} = Manifest.load("", "request-main", opts)

    assert {:error, {:turn_manifest_not_found, "session-main", "request-main"}} =
             Manifest.load("session-main", "request-main", opts)

    assert {:error, :operation_id_required} =
             Manifest.create("session-main", manifest(),
               admission: context.names[:admission],
               quota: context.names[:quota],
               writer: context.names[:writer]
             )

    assert {:ok, _created} = Manifest.create("session-main", manifest(), opts)

    assert {:error, :workspace_identity_missing} =
             Manifest.compatibility(
               "session-main",
               "request-main",
               current() |> Map.delete("workspace_id") |> Map.delete("workspace_digest"),
               opts
             )

    atom_current = Map.new(current(), fn {key, value} -> {String.to_atom(key), value} end)
    assert {:ok, %{status: :compatible}} = Manifest.compatibility("session-main", "request-main", atom_current, opts)

    assert {:error, :invalid_turn_manifest_compatibility_input} =
             Manifest.compatibility("session-main", "request-main", :invalid, opts)
  end

  test "validates digest, environment, and all-or-none credential identities" do
    assert :ok = TurnManifest.validate(manifest())
    assert {:error, :invalid_turn_manifest} = TurnManifest.validate(:invalid)

    assert {:error, :invalid_turn_manifest_digest} =
             TurnManifest.validate(Map.put(manifest(), "prompt_digest", "invalid"))

    assert {:error, :invalid_execution_environment_identity} =
             TurnManifest.validate(Map.put(manifest(), "execution_environment_id", 42))

    assert {:error, :invalid_turn_manifest_credential_selection} =
             TurnManifest.validate(Map.put(manifest(), "credential_profile_id", "incomplete"))
  end

  defp manifest do
    %{
      "request_id" => "request-main",
      "invocation_id" => "invocation-main",
      "provider_id" => "provider-main",
      "model_id" => "model-main",
      "variant_id" => "variant-main",
      "settings_digest" => @digest,
      "agent_spec_digest" => @digest,
      "prompt_digest" => @digest,
      "tool_schema_digest" => @digest,
      "skill_schema_digest" => @digest,
      "extension_descriptor_digest" => @digest,
      "protocol_digest" => @digest,
      "coding_profile_id" => "coding-main",
      "workspace_id" => "workspace-main",
      "workspace_digest" => @digest,
      "credential_profile_id" => nil,
      "credential_profile_version" => nil,
      "credential_reference_id" => nil,
      "credential_source_identity" => nil,
      "execution_environment_id" => nil
    }
  end

  defp credential_manifest do
    manifest()
    |> Map.put("credential_profile_id", "provider-credentials")
    |> Map.put("credential_profile_version", 1)
    |> Map.put("credential_reference_id", "host-openai")
    |> Map.put("credential_source_identity", "host-primary")
  end

  defp current do
    Map.take(manifest(), [
      "provider_id",
      "model_id",
      "variant_id",
      "settings_digest",
      "agent_spec_digest",
      "prompt_digest",
      "tool_schema_digest",
      "skill_schema_digest",
      "extension_descriptor_digest",
      "protocol_digest",
      "coding_profile_id",
      "execution_environment_id",
      "workspace_id",
      "workspace_digest"
    ])
  end

  defp profile do
    %{
      "profile_id" => "provider-credentials",
      "profile_version" => 1,
      "source_identity" => "host-primary",
      "references" => [
        %{
          "reference_id" => "host-openai",
          "kind" => "environment",
          "source_identity" => "host-primary",
          "lookup" => %{"name" => "OPENAI_API_KEY"}
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

  defp redact_sensitive_error({:error, {:sensitive_value_rejected, details}}),
    do: {:error, {:sensitive_value_rejected, Map.take(details, ["redacted"])}}

  defp redact_sensitive_error(other), do: other

  defp redact_forbidden_error({:error, {:forbidden_audit_value, details}}),
    do: {:error, {:forbidden_audit_value, Map.take(details, ["redacted"])}}

  defp redact_forbidden_error(other), do: other
  defp digest(character), do: "sha256:" <> String.duplicate(character, 64)
  defp unique(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
