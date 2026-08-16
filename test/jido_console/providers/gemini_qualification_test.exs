defmodule Jido.Console.Providers.GeminiQualificationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Qualification, RecordedResults}

  test "qualifies gemini-2.5-flash from recorded contracts without a live call" do
    assert {:ok, result} = Qualification.run("google", host_env: %{})
    assert Qualification.supported?(result)
    assert result.provider == "google"
    assert [model] = result.models
    assert model["identity"] == "google:gemini-2.5-flash"
    assert model["tier"] == "supported"
    assert model["eligible"]
    assert model["offline"]["outcome"] == "deny"
    assert model["preflight"]["outcome"] == "allow"
    assert model["fallback"]["outcome"] == "consent_required"
    assert model["known_gaps"] != []
    assert model["limits"]["context_tokens"] == 1_048_576
    evidence = model["capabilities"] ++ model["extra"]
    assert Enum.sort(Enum.map(evidence, & &1["dimension"])) == Enum.sort(Enum.map(Harness.dimensions(), &to_string/1))
    assert Enum.all?(evidence, &(&1["status"] == "pass" and &1["claim_matches"]))
    refute inspect(Qualification.report(result)) =~ "AIza"
  end

  test "a missing or failed contract keeps Gemini out of the supported tier" do
    {:ok, entry} = Models.show("google", "gemini-2.5-flash")

    incomplete =
      entry
      |> recorded_results()
      |> Enum.reject(&(&1.dimension == :timeout))

    identity = entry.identity

    assert {:error, {:missing_provider_contract_results, ^identity, [:timeout]}} =
             Harness.run(entry: entry, recorded_results: incomplete)

    failed =
      Enum.map(recorded_results(entry), fn result ->
        if result.dimension == :timeout do
          %{result | status: :fail, reason: "GEMINI_API_KEY=AIzaSySecretValue"}
        else
          result
        end
      end)

    assert {:ok, result} =
             Qualification.run("google",
               host_env: %{},
               recorded_results: failed
             )

    refute Qualification.supported?(result)
    refute inspect(Qualification.report(result)) =~ "AIzaSySecretValue"
  end

  test "does not change OpenAI, Anthropic, or Ollama support claims" do
    assert {:ok, openai} = Models.show("openai", "gpt-4.1-mini")
    assert {:ok, anthropic} = Models.show("anthropic", "claude-sonnet-4-20250514")
    assert {:ok, ollama} = Models.show("ollama", "llama3.2")
    assert openai.tier == :supported
    assert anthropic.tier == :supported
    assert ollama.tier == :beta
  end

  test "offline preflight does not touch the network or credentials" do
    {:ok, entry} = Models.show("google", "gemini-2.5-flash")

    assert {:error, denied} =
             Preflight.check(
               provider: "google",
               model: "gemini-2.5-flash",
               entry: entry,
               offline: true,
               network: fn -> raise "network" end,
               credentials: fn -> raise "credentials" end
             )

    assert denied.outcome == :deny
  end

  defp recorded_results(entry) do
    Enum.filter(RecordedResults.all(), &(&1.identity == entry.identity))
  end
end
