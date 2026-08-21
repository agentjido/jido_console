defmodule Jido.Console.Providers.Harness do
  @moduledoc """
  Development-only provider-contract harness for catalog capabilities.

  Default runs use recorded fixtures and never call a live provider. Live
  checks require an explicit opt-in, a timeout, and a cancellation path.
  """

  alias Jido.Console.Error
  alias Jido.Console.Models
  alias Jido.Console.Providers.{ContractResult, RecordedResults, Redaction}

  @type result :: ContractResult.t()

  @doc "Returns the contract version used by harness results."
  @spec contract_version() :: String.t()
  def contract_version, do: ContractResult.contract_version()

  @doc "Returns the contract dimensions the harness must cover."
  @spec dimensions() :: [atom()]
  def dimensions, do: ContractResult.dimensions()

  @doc "Returns accepted result statuses."
  @spec statuses() :: [atom()]
  def statuses, do: ContractResult.statuses()

  @doc "Runs recorded or opt-in live checks for one catalog entry or the full catalog."
  @spec run(keyword()) :: {:ok, [result()]} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, entries} <- entries(opts),
         {:ok, mode} <- source_mode(opts) do
      run_mode(entries, mode, opts)
    end
  end

  @doc "Builds one redacted result map for reports."
  @spec report([result()]) :: map()
  def report(results) when is_list(results) do
    %{
      "schema" => "jido.provider-contract-report",
      "schema_version" => 1,
      "contract_version" => contract_version(),
      "results" => Enum.map(results, &encode/1)
    }
  end

  defp run_mode(entries, :recorded, opts) do
    source = Keyword.get(opts, :recorded_results, RecordedResults.all())

    with {:ok, results} <- ContractResult.validate_many(source),
         selected <- select_results(results, entries),
         :ok <- require_complete_coverage(selected, entries) do
      {:ok, Redaction.redact_results(selected)}
    end
  end

  defp run_mode(entries, :live, opts) do
    results =
      Enum.flat_map(entries, fn entry ->
        Enum.map(dimensions(), &check_live(entry, &1, opts))
      end)

    {:ok, Redaction.redact_results(results)}
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

  defp check_live(entry, dimension, opts) do
    case live_runner(opts) do
      nil ->
        result(entry, dimension, :live, :blocked, "live runner is not configured")

      runner when is_function(runner, 3) ->
        case bounded_live(runner, entry, dimension, opts) do
          {:ok, status, reason}
          when status in [:pass, :fail, :blocked, :not_applicable] and is_binary(reason) ->
            result(entry, dimension, :live, status, reason)

          {:ok, status, reason} ->
            result(entry, dimension, :live, :fail, "invalid live result: #{inspect({status, reason})}")

          {:error, :cancelled} ->
            result(entry, dimension, :live, :blocked, "live check cancelled")

          {:error, :timeout} ->
            result(entry, dimension, :live, :blocked, "live check timed out")

          {:error, reason} ->
            result(entry, dimension, :live, :fail, Error.message(reason))
        end
    end
  end

  defp bounded_live(runner, entry, capability, opts) do
    timeout = Keyword.get(opts, :live_timeout_ms, 2_000)
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    if cancelled?.() do
      {:error, :cancelled}
    else
      parent = self()
      {pid, ref} = spawn_monitor(fn -> send(parent, {:live, self(), runner.(entry, capability, opts)}) end)
      await_live(pid, ref, timeout)
    end
  end

  defp await_live(pid, ref, timeout) do
    receive do
      {:live, ^pid, {:ok, status, reason}} ->
        Process.demonitor(ref, [:flush])
        {:ok, status, reason}

      {:live, ^pid, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          100 -> :ok
        end

        receive do
          {:live, ^pid, _result} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp live_runner(opts), do: Keyword.get(opts, :live_runner)

  defp select_results(results, entries) do
    identities = MapSet.new(entries, & &1.identity)
    Enum.filter(results, &MapSet.member?(identities, &1.identity))
  end

  defp require_complete_coverage(results, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      present =
        results
        |> Enum.filter(&(&1.identity == entry.identity))
        |> Enum.map(& &1.dimension)

      case dimensions() -- present do
        [] -> {:cont, :ok}
        missing -> {:halt, {:error, {:missing_provider_contract_results, entry.identity, missing}}}
      end
    end)
  end

  defp result(entry, dimension, mode, status, reason) do
    {:ok, result} =
      ContractResult.new(%{
        identity: entry.identity,
        dimension: dimension,
        contract_version: contract_version(),
        source_mode: mode,
        status: status,
        reason: reason,
        evidence_id: "#{mode}:#{entry.identity}:#{dimension}",
        test_id: "#{mode}:#{entry.identity}:#{dimension}"
      })

    result
  end

  defp encode(result) do
    %{
      "identity" => result.identity,
      "dimension" => Atom.to_string(result.dimension),
      "contract_version" => result.contract_version,
      "source_mode" => Atom.to_string(result.source_mode),
      "status" => Atom.to_string(result.status),
      "reason" => result.reason,
      "evidence_id" => result.evidence_id,
      "test_id" => result.test_id
    }
  end
end
