defmodule Jido.Console.Providers.Harness do
  @moduledoc """
  Deterministic provider-contract harness for catalog capabilities.

  Default runs use recorded fixtures and never call a live provider. Live
  checks require an explicit opt-in, a timeout, and a cancellation path.
  """

  alias Jido.Console.Models
  alias Jido.Console.Providers.Redaction

  @contract_version "jido.provider-contract.v1"
  @dimensions [
    :streaming,
    :tools,
    :multi_turn_tools,
    :structured_results,
    :cancellation,
    :timeout,
    :usage,
    :cost,
    :prompt_cache,
    :error_normalization
  ]
  @statuses [:pass, :fail, :blocked, :not_applicable]

  @type result :: %{
          provider: String.t(),
          model: String.t(),
          identity: String.t(),
          capability: atom(),
          contract_version: String.t(),
          source_mode: :recorded | :live,
          status: atom(),
          reason: String.t(),
          evidence_id: String.t(),
          test_id: String.t()
        }

  @doc "Returns the contract version used by harness results."
  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @doc "Returns the contract dimensions the harness must cover."
  @spec dimensions() :: [atom()]
  def dimensions, do: @dimensions

  @doc "Returns accepted result statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Runs recorded or opt-in live checks for one catalog entry or the full catalog."
  @spec run(keyword()) :: {:ok, [result()]} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, entries} <- entries(opts),
         {:ok, mode} <- source_mode(opts) do
      results =
        Enum.flat_map(entries, fn entry ->
          Enum.map(@dimensions, &check(entry, &1, mode, opts))
        end)

      {:ok, Redaction.redact_results(results)}
    end
  end

  @doc "Builds one redacted result map for reports."
  @spec report([result()]) :: map()
  def report(results) when is_list(results) do
    %{
      "schema" => "jido.provider-contract-report",
      "schema_version" => 1,
      "contract_version" => @contract_version,
      "results" => Enum.map(results, &encode/1)
    }
  end

  defp entries(opts) do
    case Keyword.get(opts, :entry) do
      nil -> Models.list(opts)
      entry when is_map(entry) -> {:ok, [entry]}
      _other -> {:error, :invalid_harness_entry}
    end
  end

  defp source_mode(opts) do
    cond do
      Keyword.get(opts, :live, false) != true ->
        {:ok, :recorded}

      live_opt_in?(opts) ->
        {:ok, :live}

      true ->
        {:error, :live_checks_require_explicit_opt_in}
    end
  end

  defp live_opt_in?(opts) do
    Keyword.get(opts, :live_confirmed, false) == true or
      System.get_env("JIDO_PROVIDER_LIVE") == "1"
  end

  defp check(entry, capability, :recorded, opts) do
    fixture = fixture_for(entry, capability, opts)

    status = Map.fetch!(fixture, :status)
    reason = Map.fetch!(fixture, :reason)

    result(entry, capability, :recorded, status, reason)
  end

  defp check(entry, capability, :live, opts) do
    case live_runner(opts) do
      nil ->
        result(entry, capability, :live, :blocked, "live runner is not configured")

      runner when is_function(runner, 3) ->
        case bounded_live(runner, entry, capability, opts) do
          {:ok, status, reason} when status in @statuses ->
            result(entry, capability, :live, status, reason)

          {:error, :cancelled} ->
            result(entry, capability, :live, :blocked, "live check cancelled")

          {:error, :timeout} ->
            result(entry, capability, :live, :blocked, "live check timed out")

          {:error, reason} ->
            result(entry, capability, :live, :fail, inspect(reason))
        end
    end
  end

  defp bounded_live(runner, entry, capability, opts) do
    timeout = Keyword.get(opts, :live_timeout_ms, 2_000)
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    if cancelled?.() do
      {:error, :cancelled}
    else
      task = Task.async(fn -> runner.(entry, capability, opts) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, status, reason}} -> {:ok, status, reason}
        {:ok, {:error, reason}} -> {:error, reason}
        nil -> {:error, :timeout}
        {:exit, reason} -> {:error, reason}
      end
    end
  end

  defp live_runner(opts), do: Keyword.get(opts, :live_runner)

  defp fixture_for(entry, capability, opts) do
    fixtures = Keyword.get_lazy(opts, :fixtures, &recorded_fixtures/0)
    key = {entry.provider, entry.model, capability}

    Map.get(fixtures, key, %{
      status: :not_applicable,
      reason: "no recorded fixture for #{entry.identity} #{capability}"
    })
  end

  defp recorded_fixtures do
    {:ok, entries} = Models.list()

    Map.new(
      for entry <- entries, capability <- @dimensions do
        {{entry.provider, entry.model, capability}, recorded_fixture(entry, capability)}
      end
    )
  end

  defp recorded_fixture(entry, capability) do
    feature = feature_for(entry, capability)

    cond do
      is_nil(feature) ->
        %{status: :not_applicable, reason: "capability is not declared on the catalog entry"}

      feature.state == :not_applicable ->
        %{status: :not_applicable, reason: feature.note}

      feature.state == :unsupported ->
        %{status: :fail, reason: feature.note}

      feature.state == :unknown ->
        %{status: :blocked, reason: feature.note}

      feature.state == :supported and is_binary(feature.evidence) ->
        %{status: :pass, reason: "recorded fixture matched #{feature.evidence}"}

      true ->
        %{status: :blocked, reason: "missing recorded evidence"}
    end
  end

  defp feature_for(entry, :cancellation), do: entry.cancellation
  defp feature_for(entry, :prompt_cache), do: entry.prompt_cache
  defp feature_for(entry, key), do: Map.get(entry.capabilities, key)

  defp result(entry, capability, mode, status, reason) do
    %{
      provider: entry.provider,
      model: entry.model,
      identity: entry.identity,
      capability: capability,
      contract_version: @contract_version,
      source_mode: mode,
      status: status,
      reason: reason,
      evidence_id: "harness:#{entry.identity}:#{capability}",
      test_id: "#{mode}:#{entry.identity}:#{capability}"
    }
  end

  defp encode(result) do
    %{
      "provider" => result.provider,
      "model" => result.model,
      "identity" => result.identity,
      "capability" => Atom.to_string(result.capability),
      "contract_version" => result.contract_version,
      "source_mode" => Atom.to_string(result.source_mode),
      "status" => Atom.to_string(result.status),
      "reason" => result.reason,
      "evidence_id" => result.evidence_id,
      "test_id" => result.test_id
    }
  end
end
