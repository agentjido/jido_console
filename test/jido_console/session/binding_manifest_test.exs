defmodule Jido.Console.Session.BindingManifestTest do
  use ExUnit.Case, async: false

  alias Jido.Console.AgentSource
  alias Jido.Console.Coding.Pack
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.Session.{Binding, BindingManifest}
  alias Jidoka.Session.Data

  setup do
    root = Path.join(System.tmp_dir!(), "jido-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, source} = AgentSource.resolve("builtin:jido")
    {:ok, pack} = Pack.resolve(coding_pack: Jidoka.CodingPack.id())
    {:ok, policy} = ExecutionPolicy.resolve(application_proposal: ExecutionPolicy.restricted_id(), project_root: root)

    %{root: root, source: source, pack: pack, policy: policy}
  end

  test "builds a deterministic versioned string-key manifest", context do
    first_config = Map.new([{"working_directory", "."}, {"access", ["read", "write"]}])
    second_config = Map.new(Enum.reverse(Map.to_list(first_config)))

    assert {:ok, first_binding} = build_binding(context, workspace_configuration: first_config)
    assert {:ok, second_binding} = build_binding(context, workspace_configuration: second_config)
    assert {:ok, first} = BindingManifest.new(first_binding, draft_generation: 3)
    assert {:ok, second} = BindingManifest.new(second_binding, draft_generation: 3)

    assert first == second
    assert first["version"] == 1
    assert first["lock_state"] == "draft"
    assert first["draft_generation"] == 3
    assert first["binding_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert first["source"]["digest"] == context.source.digest
    assert first["model"] == %{"id" => "openai:gpt-4.1-mini", "origin" => "agent_spec"}
    assert first["execution_policy"]["id"] == "coding.restricted"
    assert first["workspace"]["identity_digest"] == context.policy.workspace.digest
    assert first["workspace"]["configuration"] == first_config
    assert {:ok, ^first} = BindingManifest.validate(first)
  end

  test "changes the binding digest for each semantic input and not for map order", context do
    assert {:ok, original_binding} = build_binding(context)
    assert {:ok, original} = BindingManifest.new(original_binding)

    changed_source = %{
      context.source
      | digest: "sha256:" <> String.duplicate("b", 64)
    }

    assert {:ok, changed_source_binding} = build_binding(%{context | source: changed_source})
    assert {:ok, changed_source_manifest} = BindingManifest.new(changed_source_binding)
    refute changed_source_manifest["binding_digest"] == original["binding_digest"]

    assert {:ok, disabled} = Pack.resolve(coding_pack: :disabled)
    assert {:ok, changed_pack_binding} = build_binding(context, pack: disabled)
    assert {:ok, changed_pack} = BindingManifest.new(changed_pack_binding)
    refute changed_pack["binding_digest"] == original["binding_digest"]

    assert {:ok, changed_model_binding} =
             build_binding(context, model_choice: %{id: "ollama:llama3.2", origin: :api})

    assert {:ok, changed_model} = BindingManifest.new(changed_model_binding)
    refute changed_model["binding_digest"] == original["binding_digest"]

    assert {:ok, direct} = ExecutionPolicy.direct_choice(ExecutionPolicy.trusted_id(), :api)

    assert {:ok, trusted_policy} =
             ExecutionPolicy.resolve(direct_choice: direct, project_root: context.root)

    assert {:ok, changed_policy_binding} =
             Binding.build(
               context.source,
               context.pack,
               nil,
               trusted_policy,
               trusted_policy.workspace
             )

    assert {:ok, changed_policy} = BindingManifest.new(changed_policy_binding)
    refute changed_policy["binding_digest"] == original["binding_digest"]

    assert {:ok, changed_workspace_binding} =
             build_binding(context, workspace_configuration: %{"working_directory" => "lib"})

    assert {:ok, changed_workspace} = BindingManifest.new(changed_workspace_binding)
    refute changed_workspace["binding_digest"] == original["binding_digest"]
  end

  test "preserves unrelated session metadata and rejects tampering", context do
    assert {:ok, binding} = build_binding(context)
    assert {:ok, manifest} = BindingManifest.new(binding)

    assert {:ok, session} =
             Data.start(binding.bound_spec, session_id: "manifest", metadata: %{"other" => %{"value" => 1}})

    assert {:ok, stored} = BindingManifest.put(session, manifest)

    assert stored.metadata["other"] == %{"value" => 1}
    assert {:ok, ^manifest} = BindingManifest.fetch(stored)

    tampered = put_in(manifest, ["model", "id"], "ollama:llama3.2")
    assert {:error, :binding_digest_mismatch} = BindingManifest.validate(tampered)
  end

  test "does not expose private manifest identity through the safe projection", context do
    file_source = %{
      context.source
      | kind: :file,
        format: :json,
        identity: %{path: Path.join(context.root, "private-agent.json"), major_device: 1, minor_device: 2, inode: 3},
        label: "private-agent.json"
    }

    assert {:ok, binding} =
             Binding.build(file_source, context.pack, nil, context.policy, context.policy.workspace)

    assert {:ok, manifest} = BindingManifest.new(binding)
    assert manifest["source"]["identity"]["path"] =~ context.root
    refute inspect(BindingManifest.safe_projection(manifest)) =~ context.root
    assert BindingManifest.safe_projection(manifest)["agent"]["source"]["label"] == "private-agent.json"
  end

  defp build_binding(context, opts \\ []) do
    pack = Keyword.get(opts, :pack, context.pack)
    model_choice = Keyword.get(opts, :model_choice)

    Binding.build(context.source, pack, model_choice, context.policy, context.policy.workspace,
      workspace_configuration: Keyword.get(opts, :workspace_configuration, %{})
    )
  end
end
