defmodule Jido.Console.Providers.GeminiQualificationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Qualification}

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
    assert Enum.all?(model["capabilities"], &(&1["status"] == "pass"))
    refute inspect(Qualification.report(result)) =~ "AIza"
  end

  test "a missing or failed contract keeps Gemini out of the supported tier" do
    {:ok, entry} = Models.show("google", "gemini-2.5-flash")
    assert {:ok, blocked} = Harness.run(entry: entry, fixtures: %{})
    refute Enum.any?(blocked, &(&1.status == :pass))

    assert {:ok, result} =
             Qualification.run("google",
               host_env: %{},
               fixtures: %{
                 {"google", "gemini-2.5-flash", :timeout} => %{
                   status: :fail,
                   reason: "GEMINI_API_KEY=AIzaSySecretValue"
                 }
               }
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
end
