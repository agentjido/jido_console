defmodule Jido.Console.Policy.PreflightTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Policy.Preflight

  test "allows a required feature only when the catalog marks it supported" do
    entry = %{
      provider: "openai",
      model: "gpt-test",
      identity: "openai:gpt-test",
      tier: :available,
      evidence_id: "harness:openai:gpt-test",
      capabilities: %{
        streaming: %{state: :supported, evidence: "harness:streaming", note: "recorded"},
        tools: %{state: :unsupported, evidence: nil, note: "not offered"}
      },
      limits: %{context_tokens: 1},
      cost: %{class: :standard},
      cancellation: %{state: :supported, evidence: "harness:cancel", note: "recorded"},
      prompt_cache: %{state: :unknown, evidence: nil, note: "pending"},
      known_gaps: []
    }

    assert {:ok, allowed} =
             Preflight.check(
               provider: "openai",
               model: "gpt-test",
               required_features: [:streaming],
               entry: entry
             )

    assert allowed.outcome == :allow
    assert allowed.model == "gpt-test"

    assert {:error, denied} =
             Preflight.check(
               provider: "openai",
               model: "gpt-test",
               required_features: [:tools],
               entry: entry
             )

    assert denied.outcome == :deny
    assert denied.model == "gpt-test"
    assert denied.reason =~ "tools"
    assert denied.reason =~ "openai:gpt-test"
  end

  test "uses the built-in catalog for missing and unknown models" do
    assert {:ok, allowed} =
             Preflight.check(
               provider: "openai",
               model: "gpt-4.1-mini",
               required_features: [:streaming]
             )

    assert allowed.outcome == :allow

    assert {:error, missing} =
             Preflight.check(
               provider: "ollama",
               model: "llama3.2",
               required_features: [:streaming]
             )

    assert missing.outcome == :deny
    assert missing.reason =~ "ollama:llama3.2"
    assert missing.reason =~ "streaming"

    assert {:error, unknown} =
             Preflight.check(provider: "openai", model: "not-a-model", required_features: [:tools])

    assert unknown.reason =~ "unknown model"
  end

  test "offline mode denies network and does not resolve credentials" do
    network = fn -> flunk("offline mode contacted the network") end
    credentials = fn -> flunk("offline mode resolved credentials") end

    assert {:error, denied} =
             Preflight.check(
               provider: "openai",
               model: "gpt-4.1-mini",
               offline: true,
               network: network,
               credentials: credentials
             )

    assert denied.outcome == :deny
    assert denied.rule_id == "jido.policy.offline"
    assert denied.model == "gpt-4.1-mini"
  end

  test "classifies a boundary-changing fallback as consent-required" do
    assert {:error, consent} =
             Preflight.check(
               provider: "openai",
               model: "gpt-4.1-mini",
               current: %{provider: "openai", cost_class: :standard, data_boundary: :cloud},
               fallback: %{
                 provider: "anthropic",
                 model: "claude-sonnet-4-20250514",
                 cost_class: :premium,
                 data_boundary: :cloud
               }
             )

    assert consent.outcome == :consent_required
    assert consent.reason =~ "provider"
    assert consent.reason =~ "cost class"
    assert Preflight.to_jidoka(consent).outcome == :consent_required
  end

  test "a no-change fallback does not create a consent request" do
    assert {:ok, allowed} =
             Preflight.check(
               provider: "openai",
               model: "gpt-4.1-mini",
               current: %{provider: "openai", cost_class: :unknown},
               fallback: %{provider: "openai", model: "gpt-4.1-mini", cost_class: :unknown}
             )

    assert allowed.outcome == :allow
  end
end
