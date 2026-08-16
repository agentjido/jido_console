defmodule Jido.Console.Providers.HarnessTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Providers.Harness
  alias Jido.Console.Providers.Redaction

  test "deterministic checks cover every catalog dimension without a live call" do
    assert {:ok, results} = Harness.run()
    assert {:ok, entries} = Models.list()

    identities = Enum.map(entries, & &1.identity)
    capabilities = Harness.dimensions()

    assert length(results) == length(entries) * length(capabilities)

    Enum.each(entries, fn entry ->
      covered =
        results
        |> Enum.filter(&(&1.identity == entry.identity))
        |> Enum.map(& &1.capability)
        |> Enum.sort()

      assert covered == Enum.sort(capabilities)
    end)

    Enum.each(results, fn result ->
      entry = Enum.find(entries, &(&1.identity == result.identity))
      assert result.provider in Enum.map(entries, & &1.provider)
      assert result.identity in identities
      assert result.contract_version == Harness.contract_version()
      assert result.source_mode == :recorded
      assert result.status in Harness.statuses()
      assert is_binary(result.reason)
      assert is_binary(result.test_id)

      if claimed_supported?(entry, result.capability) do
        assert result.status == :pass
      else
        assert result.status != :pass
      end
    end)
  end

  test "a missing fixture is not_applicable instead of an implied pass" do
    {:ok, [entry | _rest]} = Models.list()

    assert {:ok, results} = Harness.run(entry: entry, fixtures: %{})
    omitted = Enum.find(results, &(&1.capability == :streaming))
    assert omitted.status == :not_applicable
    refute Enum.any?(results, &(&1.status == :pass))
  end

  test "live checks require opt-in and honor timeout and cancellation" do
    {:ok, [entry | _rest]} = Models.list()

    assert {:error, :live_checks_require_explicit_opt_in} = Harness.run(live: true, entry: entry)

    assert {:ok, blocked} =
             Harness.run(live: true, live_confirmed: true, entry: entry)

    assert Enum.all?(blocked, &(&1.source_mode == :live and &1.status == :blocked))

    runner = fn _entry, _capability, _opts ->
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

  test "reports redact credentials, private paths, and secrets" do
    secret = "sk-secretvalue1234 and /Users/mhostetler/secret OPENAI_API_KEY=abc123"
    assert Redaction.redact(secret) =~ "[redacted]"
    refute Redaction.redact(secret) =~ "sk-secretvalue1234"
    refute Redaction.redact(secret) =~ "/Users/mhostetler"
    refute Redaction.redact(secret) =~ "abc123"

    {:ok, [entry | _rest]} = Models.list()

    fixtures = %{
      {entry.provider, entry.model, :streaming} => %{
        status: :blocked,
        reason: "provider said OPENAI_API_KEY=abc123 at /Users/mhostetler/.env"
      }
    }

    assert {:ok, results} = Harness.run(entry: entry, fixtures: fixtures)
    streaming = Enum.find(results, &(&1.capability == :streaming))
    refute streaming.reason =~ "abc123"
    refute streaming.reason =~ "/Users/mhostetler"
    assert Harness.report(results)["results"] != []
  end

  defp claimed_supported?(entry, capability) do
    case Map.fetch(entry.capabilities, capability) do
      {:ok, %{state: :supported}} -> true
      _other -> false
    end
  end
end
