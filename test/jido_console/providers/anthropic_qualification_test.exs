defmodule Jido.Console.Providers.AnthropicQualificationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Qualification}

  test "qualifies claude-sonnet-4 from recorded contracts without a live call" do
    assert {:ok, result} = Qualification.run("anthropic", host_env: %{})
    assert Qualification.supported?(result)
    assert result.provider == "anthropic"
    assert [model] = result.models
    assert model["identity"] == "anthropic:claude-sonnet-4-20250514"
    assert model["tier"] == "supported"
    assert model["eligible"]
    assert model["offline"]["outcome"] == "deny"
    assert model["preflight"]["outcome"] == "allow"
    assert model["fallback"]["outcome"] == "consent_required"
    assert model["known_gaps"] != []
    assert model["limits"]["context_tokens"] == 200_000
    assert Enum.all?(model["capabilities"], &(&1["status"] == "pass"))
    refute inspect(Qualification.report(result)) =~ "sk-"
  end

  test "a missing or failed contract keeps Anthropic out of the supported tier" do
    {:ok, entry} = Models.show("anthropic", "claude-sonnet-4-20250514")
    assert {:ok, blocked} = Harness.run(entry: entry, fixtures: %{})
    refute Enum.any?(blocked, &(&1.status == :pass))

    assert {:ok, result} =
             Qualification.run("anthropic",
               host_env: %{},
               fixtures: %{
                 {"anthropic", "claude-sonnet-4-20250514", :tools} => %{
                   status: :blocked,
                   reason: "ANTHROPIC_API_KEY=sk-ant-secret"
                 }
               }
             )

    refute Qualification.supported?(result)
    refute inspect(Qualification.report(result)) =~ "sk-ant-secret"
  end

  test "does not change OpenAI or Gemini support claims" do
    assert {:ok, openai} = Models.show("openai", "gpt-4.1-mini")
    assert {:ok, gemini} = Models.show("google", "gemini-2.5-flash")
    assert openai.tier == :supported
    assert gemini.tier == :available
  end

  test "offline preflight does not touch the network or credentials" do
    {:ok, entry} = Models.show("anthropic", "claude-sonnet-4-20250514")

    assert {:error, denied} =
             Preflight.check(
               provider: "anthropic",
               model: "claude-sonnet-4-20250514",
               entry: entry,
               offline: true,
               network: fn -> raise "network" end,
               credentials: fn -> raise "credentials" end
             )

    assert denied.outcome == :deny
  end
end
