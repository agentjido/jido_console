defmodule Jido.Console.Providers.OpenAIQualificationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Qualification, RecordedResults}

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
    evidence = model["capabilities"] ++ model["extra"]
    assert Enum.sort(Enum.map(evidence, & &1["dimension"])) == Enum.sort(Enum.map(Harness.dimensions(), &to_string/1))
    assert Enum.all?(evidence, &(&1["status"] == "pass" and &1["claim_matches"]))
    assert Enum.all?(evidence, &is_binary(&1["evidence_id"]))
    assert Enum.all?(evidence, &is_binary(&1["test_id"]))
    refute inspect(Qualification.report(result)) =~ "sk-"
    refute inspect(result.credentials) =~ "sk-"
  end

  test "a missing or failed contract keeps OpenAI out of the supported tier" do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")

    incomplete =
      entry
      |> recorded_results()
      |> Enum.reject(&(&1.dimension == :streaming))

    identity = entry.identity

    assert {:error, {:missing_provider_contract_results, ^identity, [:streaming]}} =
             Harness.run(entry: entry, recorded_results: incomplete)

    failed =
      Enum.map(recorded_results(entry), fn result ->
        if result.dimension == :streaming, do: %{result | status: :fail}, else: result
      end)

    assert {:ok, result} =
             Qualification.run("openai",
               host_env: %{},
               recorded_results: failed
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

  defp recorded_results(entry) do
    Enum.filter(RecordedResults.all(), &(&1.identity == entry.identity))
  end
end
