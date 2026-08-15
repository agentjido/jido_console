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
end
