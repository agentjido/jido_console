defmodule Jido.Console.Models.CatalogTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Models.Catalog

  test "loads a validated v0.1 catalog with complete identities" do
    assert {:ok, catalog} = Models.load()
    assert catalog.revision == "jido.models.v0.1"
    assert catalog.entries != []

    Enum.each(catalog.entries, fn entry ->
      assert entry.identity == entry.provider <> ":" <> entry.model
      assert entry.tier in Catalog.tiers()
      assert is_binary(entry.evidence_id) and entry.evidence_id != ""
      assert map_size(entry.capabilities) == 6
      assert is_map(entry.limits) and map_size(entry.limits) > 0
      assert is_map(entry.cost) and map_size(entry.cost) > 0
      assert is_map(entry.cancellation)
      assert is_map(entry.prompt_cache)
      assert is_list(entry.known_gaps)
      assert entry.metadata.source == :llm_db

      if entry.provider in ["openai", "anthropic", "google"] do
        assert entry.tier == :supported
        assert String.starts_with?(entry.evidence_id, "harness:")
      else
        refute entry.tier == :supported
      end
    end)
  end

  test "keeps Ollama in the beta tier" do
    assert {:ok, entry} = Models.show("ollama", "llama3.2")
    assert entry.tier == :beta
    assert entry.evidence_id == "pending:ollama-beta"
  end

  test "reads limits, prices, and lifecycle facts from LLMDB" do
    assert {:ok, openai} = Models.show("openai", "gpt-4.1-mini")
    assert openai.limits == %{context_tokens: 1_047_576, output_tokens: 32_768}
    assert openai.cost.input == 0.4
    assert openai.cost.output == 1.6
    assert openai.metadata.source == :llm_db

    assert {:ok, anthropic} = Models.show("anthropic", "claude-sonnet-4-20250514")
    assert anthropic.metadata.deprecated
    assert Enum.any?(anthropic.known_gaps, &String.starts_with?(&1, "LLMDB marks this model deprecated"))
  end

  test "fails closed when allowlisted model metadata is missing or not executable" do
    policy = valid_policy("openai:gpt-test")

    assert {:error, {:model_metadata_unavailable, "openai:gpt-test", :not_found}} =
             Catalog.load(model_policy: [policy], model_resolver: fn _identity -> {:error, :not_found} end)

    model = LLMDB.Model.new!(%{id: "gpt-test", provider: :openai})

    assert {:error, {:supported_model_not_executable, "openai:gpt-test"}} =
             Catalog.load(model_policy: [policy], model_resolver: fn _identity -> {:ok, model} end)
  end

  test "rejects an unknown tier, duplicate identity, and missing field" do
    base = valid_entry()

    assert {:error, {:unknown_tier, :gold, "openai:gpt-test"}} =
             Catalog.validate([Map.put(base, :tier, :gold)])

    assert {:error, {:duplicate_identity, "openai:gpt-test"}} =
             Catalog.validate([base, base])

    assert {:error, {:missing_field, :cost, "openai:gpt-test"}} =
             Catalog.validate([Map.delete(base, :cost)])
  end

  test "does not present unsupported features or missing evidence as supported" do
    claimed =
      valid_entry()
      |> Map.put(:tier, :supported)
      |> Map.put(:evidence_id, "pending:m1e10")

    assert {:error, {:supported_without_evidence, "openai:gpt-test"}} = Catalog.validate([claimed])

    feature = %{state: :supported, evidence: nil, note: "claimed"}
    bad_feature = claimed |> Map.put(:evidence_id, "contract:openai") |> Map.put(:cancellation, feature)

    assert {:error, {:unsupported_feature_claimed, "openai:gpt-test"}} =
             Catalog.validate([bad_feature])
  end

  test "list and show consume the same validated catalog" do
    assert {:ok, entries} = Models.list()
    assert {:ok, shown} = Models.show("openai", "gpt-4.1-mini")
    assert shown in entries
    assert {:error, {:unknown_model, "openai:missing"}} = Models.show("openai", "missing")
  end

  defp valid_entry do
    feature = %{state: :unknown, evidence: nil, note: "pending"}

    %{
      provider: "openai",
      model: "gpt-test",
      tier: :available,
      evidence_id: "pending:test",
      capabilities:
        Map.new(
          [:streaming, :tools, :multi_turn_tools, :structured_results, :cancellation, :timeout],
          &{&1, feature}
        ),
      limits: %{context_tokens: :unknown},
      cost: %{class: :unknown},
      cancellation: feature,
      prompt_cache: feature,
      known_gaps: ["none claimed"]
    }
  end

  defp valid_policy(identity) do
    %{
      identity: identity,
      tier: :supported,
      evidence_id: "contract:test",
      contract_note: "Test contract",
      prompt_cache_note: "Test prompt cache contract",
      known_gaps: []
    }
  end
end
