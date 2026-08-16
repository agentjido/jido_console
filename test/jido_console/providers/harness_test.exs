defmodule Jido.Console.Providers.HarnessTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Providers.{ContractResult, Harness, RecordedResults, Redaction}

  test "recorded results cover every model and dimension without a live call" do
    assert {:ok, results} = Harness.run()
    assert {:ok, entries} = Models.list()

    assert length(results) == length(entries) * length(Harness.dimensions())

    Enum.each(entries, fn entry ->
      model_results = Enum.filter(results, &(&1.identity == entry.identity))

      assert Enum.sort(Enum.map(model_results, & &1.dimension)) ==
               Enum.sort(Harness.dimensions())

      Enum.each(model_results, fn result ->
        assert result.contract_version == Harness.contract_version()
        assert result.source_mode == :recorded
        assert result.status in Harness.statuses()
        assert is_binary(result.reason) and result.reason != ""
        assert is_binary(result.evidence_id) and result.evidence_id != ""
        assert is_binary(result.test_id) and result.test_id != ""
      end)
    end)
  end

  test "catalog claims cannot create a missing recorded result" do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")

    results =
      entry
      |> recorded_results()
      |> Enum.reject(&(&1.dimension == :streaming))

    assert {:error, {:missing_provider_contract_results, "openai:gpt-4.1-mini", [:streaming]}} =
             Harness.run(entry: entry, recorded_results: results)
  end

  test "duplicate recorded evidence is rejected" do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")
    [first | _rest] = results = recorded_results(entry)

    assert {:error, {:duplicate_provider_contract_result, {"openai:gpt-4.1-mini", dimension}}} =
             Harness.run(entry: entry, recorded_results: [first | results])

    assert dimension == first.dimension
  end

  test "corrupt recorded evidence is rejected" do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")
    [first | rest] = recorded_results(entry)

    corrupt = Map.put(first, :contract_version, "jido.provider-contract.invalid")

    assert {:error, {:unsupported_provider_contract_version, "jido.provider-contract.invalid"}} =
             Harness.run(entry: entry, recorded_results: [corrupt | rest])

    assert {:error, :invalid_provider_contract_result_fields} =
             Harness.run(entry: entry, recorded_results: [Map.delete(first, :test_id) | rest])
  end

  test "live checks require opt-in and honor timeout and cancellation" do
    {:ok, [entry | _rest]} = Models.list()

    assert {:error, :live_checks_require_explicit_opt_in} = Harness.run(live: true, entry: entry)

    assert {:ok, blocked} =
             Harness.run(live: true, live_confirmed: true, entry: entry)

    assert Enum.all?(blocked, &(&1.source_mode == :live and &1.status == :blocked))

    runner = fn _entry, _dimension, _opts ->
      Process.sleep(5_000)
      {:ok, :pass, "should not finish"}
    end

    assert {:ok, timed_out} =
             Harness.run(
               live: true,
               live_confirmed: true,
               live_runner: runner,
               live_timeout_ms: 20,
               entry: entry
             )

    assert Enum.all?(timed_out, &(&1.status == :blocked))
    assert Enum.any?(timed_out, &(&1.reason =~ "timed out"))

    assert {:ok, cancelled} =
             Harness.run(
               live: true,
               live_confirmed: true,
               live_runner: runner,
               cancelled?: fn -> true end,
               entry: entry
             )

    assert Enum.any?(cancelled, &(&1.reason =~ "cancelled"))
  end

  test "reports preserve result identity and redact secrets" do
    secret = "sk-secretvalue1234 and /Users/mhostetler/secret OPENAI_API_KEY=abc123"
    assert Redaction.redact(secret) =~ "[redacted]"
    refute Redaction.redact(secret) =~ "sk-secretvalue1234"
    refute Redaction.redact(secret) =~ "/Users/mhostetler"
    refute Redaction.redact(secret) =~ "abc123"

    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")

    results =
      Enum.map(recorded_results(entry), fn result ->
        if result.dimension == :streaming do
          %{result | reason: "provider said OPENAI_API_KEY=abc123 at /Users/mhostetler/.env"}
        else
          result
        end
      end)

    assert {:ok, checked} = Harness.run(entry: entry, recorded_results: results)
    streaming = Enum.find(checked, &(&1.dimension == :streaming))
    refute streaming.reason =~ "abc123"
    refute streaming.reason =~ "/Users/mhostetler"

    assert %{
             "identity" => "openai:gpt-4.1-mini",
             "dimension" => "streaming",
             "evidence_id" => "harness:openai:gpt-4.1-mini",
             "test_id" => "openai-gpt-4.1-mini-streaming"
           } = Enum.find(Harness.report(checked)["results"], &(&1["dimension"] == "streaming"))
  end

  defp recorded_results(entry) do
    RecordedResults.all()
    |> Enum.filter(&(&1.identity == entry.identity))
    |> Enum.map(fn attrs ->
      {:ok, result} = ContractResult.new(attrs)
      result
    end)
  end
end
