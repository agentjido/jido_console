defmodule Jido.Console.Coding.ProviderOptionsTest do
  use ExUnit.Case, async: false

  alias Jido.Console.AgentSource
  alias Jido.Console.Coding.{Pack, ProviderOptions}
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.Session.Binding

  setup do
    root = Path.join(System.tmp_dir!(), "jido-provider-options-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, source} = AgentSource.resolve("builtin:jido")
    {:ok, pack} = Pack.resolve(coding_pack: Jidoka.CodingPack.id())
    {:ok, policy} = ExecutionPolicy.resolve(application_proposal: ExecutionPolicy.restricted_id(), project_root: root)
    {:ok, binding} = Binding.build(source, pack, nil, policy, policy.workspace)
    %{binding: binding}
  end

  test "keeps every semantic bound-spec field unchanged", %{binding: binding} do
    assert {:ok, spec} = ProviderOptions.tune_spec(binding, model: binding.model_id)
    assert spec === binding.bound_spec

    assert {:error, :provider_model_override_forbidden} =
             ProviderOptions.tune_spec(binding, model: "ollama:llama3.2")

    assert {:error, :provider_model_override_forbidden} =
             ProviderOptions.tune_spec(binding, llm_opts: [model: "ollama:llama3.2"])
  end

  test "returns only transport settings and keeps policy turn options separate", %{binding: binding} do
    assert {:ok, [llm_opts: llm_opts]} =
             ProviderOptions.runtime_opts(binding,
               llm_opts: [receive_timeout: 2_000],
               provider_options: [organization: "org-test"]
             )

    assert llm_opts[:receive_timeout] == 2_000
    assert llm_opts[:provider_options] == [organization: "org-test"]

    assert ProviderOptions.turn_opts("coding.restricted", "anthropic:claude-test") ==
             [max_parallel_operations: 1]

    assert ProviderOptions.turn_opts(nil, "anthropic:claude-test") == []
  end
end
