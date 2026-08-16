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

      assert Map.keys(entry.capabilities) |> Enum.sort() ==
               Enum.sort([
                 :streaming,
                 :tools,
                 :multi_turn_tools,
                 :structured_results,
                 :cancellation,
                 :timeout,
                 :prompt_cache
               ])

      assert is_map(entry.limits) and map_size(entry.limits) > 0
      assert is_map(entry.cost) and map_size(entry.cost) > 0
      assert is_map(entry.capabilities.cancellation)
      assert is_map(entry.capabilities.prompt_cache)
      refute Map.has_key?(entry, :cancellation)
      refute Map.has_key?(entry, :prompt_cache)
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

    bad_feature =
      claimed
      |> Map.put(:evidence_id, "contract:openai")
      |> put_in([:capabilities, :cancellation], feature)

    assert {:error, {:unsupported_feature_claimed, "openai:gpt-test"}} =
             Catalog.validate([bad_feature])
  end

  test "rejects features outside the capability map and mixed capability keys" do
    entry = valid_entry()
    feature = %{state: :unknown, evidence: nil, note: "duplicate"}

    assert {:error, {:feature_outside_capabilities, :cancellation, "openai:gpt-test"}} =
             Catalog.validate([Map.put(entry, :cancellation, feature)])

    assert {:error, {:feature_outside_capabilities, :prompt_cache, "openai:gpt-test"}} =
             Catalog.validate([Map.put(entry, "prompt_cache", feature)])

    mixed = put_in(entry, [:capabilities, "streaming"], feature)

    assert {:error, {:duplicate_capability, :streaming, "openai:gpt-test"}} =
             Catalog.validate([mixed])

    policy = Map.put(valid_policy("openai:gpt-test"), :contract_note, "old form")
    model = executable_model("gpt-test")

    assert {:error, {:feature_outside_capabilities, :contract_note, "openai:gpt-test"}} =
             Catalog.load(model_policy: [policy], model_resolver: fn _identity -> {:ok, model} end)
  end

  test "rejects every malformed catalog entry shape" do
    base = valid_entry()
    feature = base.capabilities.streaming

    assert Catalog.revision() == "jido.models.v0.1"
    assert {:ok, %{entries: [_entry]}} = Catalog.load(entries: [base])
    assert {:error, :invalid_catalog} = Catalog.validate(:invalid)
    assert Catalog.claimed_features(base) == []

    invalid_entries = [
      Map.delete(base, :provider),
      Map.put(base, :provider, ""),
      Map.delete(base, :model),
      Map.delete(base, :evidence_id),
      Map.delete(base, :capabilities),
      put_in(base, [:capabilities, :streaming], :invalid),
      put_in(base, [:capabilities, :streaming], %{feature | state: :invalid}),
      put_in(base, [:capabilities, :streaming], Map.delete(feature, :note)),
      Map.update!(base, :capabilities, &Map.delete(&1, :streaming)),
      put_in(base, [:capabilities, :unknown], feature),
      put_in(base, [:capabilities, 42], feature),
      Map.put(base, :limits, %{}),
      Map.put(base, :known_gaps, [:invalid]),
      Map.put(base, :known_gaps, :invalid),
      Map.put(base, :metadata, :invalid)
    ]

    Enum.each(invalid_entries, fn entry ->
      assert {:error, _reason} = Catalog.validate([entry])
    end)

    string_entry =
      base
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("tier", "available")

    assert {:ok, %{entries: [%{tier: :available, metadata: %{source: :declared}}]}} =
             Catalog.validate([string_entry])
  end

  test "fails closed for every malformed policy and resolver result" do
    policy = valid_policy("openai:gpt-test")
    model = executable_model("gpt-test")

    assert {:error, :empty_model_policy} =
             Catalog.load(model_policy: [], model_resolver: fn _identity -> {:ok, model} end)

    assert {:error, :invalid_model_policy} =
             Catalog.load(model_policy: :invalid, model_resolver: fn _identity -> {:ok, model} end)

    assert {:error, :invalid_model_policy} =
             Catalog.load(model_policy: [policy], model_resolver: :invalid)

    assert {:error, :invalid_model_policy_entry} =
             Catalog.load(model_policy: [:invalid], model_resolver: fn _identity -> {:ok, model} end)

    invalid_policies = [
      Map.put(policy, :identity, "invalid"),
      Map.delete(policy, :identity),
      Map.put(policy, :tier, :gold),
      Map.delete(policy, :evidence_id),
      Map.put(policy, :capabilities, :invalid),
      Map.put(policy, :known_gaps, [:invalid]),
      Map.put(policy, :known_gaps, :invalid)
    ]

    Enum.each(invalid_policies, fn invalid ->
      assert {:error, _reason} =
               Catalog.load(model_policy: [invalid], model_resolver: fn _identity -> {:ok, model} end)
    end)

    assert {:error, {:invalid_model_metadata_result, "openai:gpt-test", :invalid}} =
             Catalog.load(model_policy: [policy], model_resolver: fn _identity -> :invalid end)

    assert {:error, {:model_metadata_unavailable, "openai:gpt-test", RuntimeError}} =
             Catalog.load(model_policy: [policy], model_resolver: fn _identity -> raise "missing" end)

    mismatch = executable_model("other")

    assert {:error, {:model_identity_mismatch, "openai:gpt-test", "openai:other"}} =
             Catalog.load(model_policy: [policy], model_resolver: fn _identity -> {:ok, mismatch} end)

    for {field, reason} <- [
          {:retired, :supported_model_retired},
          {:catalog_only, :supported_model_catalog_only}
        ] do
      unavailable = Map.put(model, field, true)

      assert {:error, {^reason, "openai:gpt-test"}} =
               Catalog.load(model_policy: [policy], model_resolver: fn _identity -> {:ok, unavailable} end)
    end
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
          [
            :streaming,
            :tools,
            :multi_turn_tools,
            :structured_results,
            :cancellation,
            :timeout,
            :prompt_cache
          ],
          &{&1, feature}
        ),
      limits: %{context_tokens: :unknown},
      cost: %{class: :unknown},
      known_gaps: ["none claimed"]
    }
  end

  defp valid_policy(identity) do
    feature = %{state: :supported, evidence: "contract:test", note: "Test contract"}

    %{
      identity: identity,
      tier: :supported,
      evidence_id: "contract:test",
      capabilities:
        Map.new(
          [
            :streaming,
            :tools,
            :multi_turn_tools,
            :structured_results,
            :cancellation,
            :timeout,
            :prompt_cache
          ],
          &{&1, feature}
        ),
      known_gaps: []
    }
  end

  defp executable_model(model) do
    LLMDB.Model.new!(%{
      id: model,
      provider: :openai,
      provider_model_id: model,
      execution: %{text: %{supported: true}}
    })
  end
end
