defmodule Jido.Console.Providers.OpenAIQualificationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Qualification}

  test "qualifies gpt-4.1-mini from recorded contracts without a live call" do
    assert {:ok, result} = Qualification.run("openai", host_env: %{})
    assert Qualification.supported?(result)
    assert result.provider == "openai"
    assert [model] = result.models
    assert model["identity"] == "openai:gpt-4.1-mini"
    assert model["tier"] == "supported"
    assert model["eligible"]
    assert model["offline"]["outcome"] == "deny"
    assert model["preflight"]["outcome"] == "allow"
    assert model["fallback"]["outcome"] == "consent_required"
    assert model["known_gaps"] != []
    assert model["limits"]["context_tokens"] == 1_047_576
    assert Enum.all?(model["capabilities"], &(&1["status"] == "pass"))
    assert Enum.all?(model["extra"], &(&1["status"] == "pass"))
    refute inspect(Qualification.report(result)) =~ "sk-"
    refute inspect(result.credentials) =~ "sk-"
  end

  test "a missing or failed contract keeps OpenAI out of the supported tier" do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")

    assert {:ok, blocked} = Harness.run(entry: entry, fixtures: %{})
    refute Enum.any?(blocked, &(&1.status == :pass))

    assert {:ok, result} =
             Qualification.run("openai",
               host_env: %{},
               fixtures: %{
                 {"openai", "gpt-4.1-mini", :streaming} => %{
                   status: :fail,
                   reason: "OPENAI_API_KEY=sk-secretvalue"
                 }
               }
             )

    assert hd(result.models)["tier"] == "available"
    refute Qualification.supported?(result)
    refute inspect(Qualification.report(result)) =~ "sk-secretvalue"
  end

  test "does not change Ollama support claims" do
    assert {:ok, ollama} = Models.show("ollama", "llama3.2")
    assert ollama.tier == :beta
  end

  test "offline preflight does not touch the network or credentials" do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")

    assert {:error, denied} =
             Preflight.check(
               provider: "openai",
               model: "gpt-4.1-mini",
               entry: entry,
               offline: true,
               network: fn -> raise "network" end,
               credentials: fn -> raise "credentials" end
             )

    assert denied.outcome == :deny
    assert denied.rule_id == "jido.policy.offline"
  end
end
