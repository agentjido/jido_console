defmodule Jido.Console.Coding.ProviderOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.ProviderOptions
  alias Jidoka.Agent

  test "applies provider-specific bounded local generation options" do
    cases = [
      {"openai:gpt-5-test", %{max_tokens: 4_000, reasoning_effort: :low}},
      {"openai:gpt-4.1-mini", %{max_tokens: 4_000, temperature: 0.0}},
      {"anthropic:claude-test", %{max_tokens: 4_000, temperature: 0.0}},
      {"test:model", %{max_tokens: 4_000}}
    ]

    for {model, expected} <- cases do
      assert {:ok, tuned} =
               ProviderOptions.tune_spec(spec(), %{profile_id: "coding.local"}, model: model)

      assert tuned.generation.params == expected
      assert tuned.runtime_defaults.max_model_turns == 12
      assert tuned.instructions =~ "The first valid start_line or end_line value is 1."
    end

    assert ProviderOptions.turn_opts("coding.local", "anthropic:claude-test") ==
             [max_parallel_operations: 1]

    assert ProviderOptions.turn_opts(nil, "anthropic:claude-test") == []
  end

  defp spec do
    Agent.Spec.new!(
      id: "provider-options-agent",
      instructions: "Test provider options.",
      model: %{provider: :test, id: "model"}
    )
  end
end
