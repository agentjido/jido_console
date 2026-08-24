defmodule Jido.Console.Session.BindingTest do
  use ExUnit.Case, async: false

  alias Jido.Console.AgentSource
  alias Jido.Console.AgentSource.Record
  alias Jido.Console.Coding.Pack
  alias Jido.Console.Digest
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jido.Console.Session.Binding
  alias Jidoka.Agent.Spec.{Generation, Memory}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-binding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, source} = AgentSource.resolve("builtin:jido")
    {:ok, policy} = ExecutionPolicy.resolve(application_proposal: ExecutionPolicy.restricted_id(), project_root: root)
    {:ok, pack} = Pack.resolve(coding_pack: Jidoka.CodingPack.id())

    %{root: root, source: source, policy: policy, pack: pack}
  end

  test "builds a bound semantic spec without replacing agent behavior", context do
    base = context.source.base_spec

    spec =
      Jidoka.Agent.Spec.new!(%{
        base
        | instructions: "Agent behavior must stay.",
          generation: Generation.new!(params: %{temperature: 0.7, max_tokens: 777}),
          runtime_defaults: %{"max_model_turns" => 99, "timeout_ms" => 999_999},
          memory: Memory.new!(capture: :conversation, inject: :context, max_entries: 99)
      })

    source = source_for(context.source, spec)

    assert {:ok, binding} =
             Binding.build(source, context.pack, nil, context.policy, context.policy.workspace, thread_id: "thread-one")

    assert binding.base_spec == spec
    assert binding.bound_spec.instructions =~ "Agent behavior must stay."
    assert binding.bound_spec.generation == spec.generation
    assert binding.bound_spec.runtime_defaults.max_model_turns == 12
    assert binding.bound_spec.runtime_defaults.timeout_ms == 180_000
    assert binding.bound_spec.memory.scope == :session
    assert binding.bound_spec.memory.namespace == nil
    assert binding.bound_spec.memory.capture == :conversation
    assert binding.bound_spec.memory.inject == :context
    assert binding.bound_spec.memory.max_entries == 20
    assert Jidoka.Config.model_ref(binding.bound_spec.model) == binding.model_id
  end

  test "uses TUI, direct, and agent model precedence without a catalog fallback", context do
    choices = [
      %{id: "ollama:llama3.2", origin: :api},
      %{id: "anthropic:claude-sonnet-4-20250514", origin: :tui}
    ]

    assert {:ok, binding} =
             Binding.build(context.source, context.pack, choices, context.policy, context.policy.workspace)

    assert binding.model_id == "anthropic:claude-sonnet-4-20250514"
    assert binding.model_origin == :tui

    missing_model = %{context.source.base_spec | model: nil}
    missing_source = source_for(context.source, missing_model, base_spec_digest: "sha256:" <> String.duplicate("a", 64))

    assert {:needs_model, %{reason: :missing_model}} =
             Binding.build(missing_source, context.pack, nil, context.policy, context.policy.workspace,
               interactive?: true,
               verify_base_spec_digest?: false
             )

    assert {:error, %Jido.Console.Error.ConfigurationError{}} =
             Binding.build(missing_source, context.pack, nil, context.policy, context.policy.workspace,
               verify_base_spec_digest?: false
             )
  end

  test "preserves a direct model override across an agent change", context do
    assert {:ok, direct} =
             Binding.build(
               context.source,
               context.pack,
               %{id: "ollama:llama3.2", origin: :cli},
               context.policy,
               context.policy.workspace
             )

    changed_spec = put_model(context.source.base_spec, "anthropic:claude-sonnet-4-20250514")
    changed_source = source_for(context.source, changed_spec)

    assert {:ok, rebound} = Binding.rebind_source(direct, changed_source)
    assert rebound.model_id == "ollama:llama3.2"
    assert rebound.model_origin == :cli

    assert {:ok, from_agent} =
             Binding.build(context.source, context.pack, nil, context.policy, context.policy.workspace)

    assert {:ok, rebound_from_agent} = Binding.rebind_source(from_agent, changed_source)
    assert rebound_from_agent.model_id == "anthropic:claude-sonnet-4-20250514"
    assert rebound_from_agent.model_origin == :agent_spec
  end

  test "uses one allowlisted safe context and rejects reserved caller namespaces", context do
    assert {:ok, binding} =
             Binding.build(context.source, context.pack, nil, context.policy, context.policy.workspace)

    assert %{
             "jido_console" => %{
               "agent" => %{
                 "id" => "jido",
                 "source" => %{"kind" => "builtin", "digest" => source_digest}
               },
               "coding_pack" => %{"id" => "jido.coding_pack", "status" => "enabled"},
               "execution_policy" => %{"id" => "coding.restricted"},
               "workspace" => %{"identity_digest" => workspace_digest}
             }
           } = Binding.safe_context(binding)

    assert source_digest == context.source.digest
    assert workspace_digest == context.policy.workspace.digest
    refute inspect(Binding.safe_context(binding)) =~ context.root
    refute inspect(Binding.safe_context(binding)) =~ "adapter"
    refute inspect(Binding.safe_context(binding)) =~ "credential"

    assert {:ok, merged} = Binding.merge_context(binding, %{"caller" => %{"ok" => true}})
    assert merged["caller"] == %{"ok" => true}
    assert merged["jido_console"] == Binding.safe_context(binding)["jido_console"]

    for key <- ["jido_console", :jido_console, "coding", :coding] do
      assert {:error, {:reserved_context_namespace, _namespace}} =
               Binding.merge_context(binding, %{key => %{"forged" => true}})
    end
  end

  test "keeps semantic and runtime-definition fingerprints separate", context do
    first_definition = %{"operations" => [%{"name" => "coding.read", "revision" => 1}]}
    second_definition = %{"operations" => [%{"name" => "coding.read", "revision" => 2}]}

    assert {:ok, first} =
             Binding.build(context.source, context.pack, nil, context.policy, context.policy.workspace,
               runtime_definition: first_definition
             )

    assert {:ok, second} =
             Binding.build(context.source, context.pack, nil, context.policy, context.policy.workspace,
               runtime_definition: second_definition
             )

    assert first.bound_spec_digest == second.bound_spec_digest
    refute first.runtime_definition_fingerprint == second.runtime_definition_fingerprint

    for unsafe <- [fn -> :unsafe end, self(), make_ref()] do
      assert {:error, {:nonportable_runtime_definition, _reason}} =
               ExtensionSetup.runtime_definition_fingerprint(%{"unsafe" => unsafe})
    end
  end

  defp put_model(spec, identity) do
    Jidoka.Agent.Spec.new!(%{spec | model: identity})
  end

  defp source_for(source, spec, overrides \\ []) do
    base_spec_digest =
      Keyword.get_lazy(overrides, :base_spec_digest, fn ->
        Digest.semantic(:agent_base_spec, Jidoka.project(spec))
      end)

    Record.build(
      base_spec: spec,
      identity: Keyword.get(overrides, :identity, source.identity),
      kind: Keyword.get(overrides, :kind, source.kind),
      format: Keyword.get(overrides, :format, source.format),
      byte_size: source.byte_size,
      digest: Keyword.get(overrides, :digest, source.digest),
      base_spec_digest: base_spec_digest,
      agent_id: spec.id,
      label: source.label
    )
  end
end
