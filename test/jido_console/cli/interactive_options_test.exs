defmodule Jido.Console.InteractiveOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.InteractiveOptions

  test "validates interactive parser output" do
    assert {:ok, %{help: true, model: "openai:model"}} =
             InteractiveOptions.parse(help: true, model: "openai:model")

    assert {:error, {:invalid_interactive_options, _errors}} =
             InteractiveOptions.parse(help: "true", unknown: true)
  end

  test "normalizes canonical agent and policy options with CLI origin" do
    assert {:ok, options} =
             InteractiveOptions.parse(
               agent: "agents/review agent.yaml",
               execution_policy: "coding.trusted-workspace",
               model: "openai:gpt-4.1-mini"
             )

    assert options.agent_source == "agents/review agent.yaml"
    assert options.execution_policy == "coding.trusted-workspace"
    assert options.execution_policy_direct_choice.origin == :cli
    assert options.model_origin == :cli
  end

  test "normalizes the legacy policy input with one local warning" do
    assert {:ok, options} = InteractiveOptions.parse(coding_profile: "coding.local")
    assert options.execution_policy == "coding.trusted-workspace"
    assert options.deprecation_warnings == ["coding profile is deprecated; use execution policy"]
    assert options.execution_policy_direct_choice.legacy?
  end

  test "rejects conflicts and repeats before it builds a map" do
    assert {:error, :conflicting_execution_policy_inputs} =
             InteractiveOptions.parse(
               execution_policy: "coding.restricted",
               coding_profile: "coding.restricted"
             )

    assert {:error, {:repeated_interactive_option, :execution_policy}} =
             InteractiveOptions.parse(
               execution_policy: "coding.restricted",
               execution_policy: "coding.restricted"
             )

    assert {:error, {:repeated_interactive_option, :agent}} =
             InteractiveOptions.parse(agent: "one.yaml", agent: "two.yaml")
  end
end
