defmodule Jido.Console.Automation.Replay do
  @moduledoc "Trusted host-profile loading and runtime evidence for offline capability replay."

  alias Jido.Console.Automation.{Contract, ReplayProjection, ResultValue}
  alias Jidoka.ExecutionEnvironment.Contract, as: EnvironmentContract
  alias Jidoka.Replay.Capabilities, as: ReplayCapabilities
  alias Jidoka.Replay.Fixture
  alias Jidoka.Replay.Recorder

  @default_max_bytes 8_000_000
  @absolute_max_bytes 32_000_000
  @config_keys ~w(mode fixture_digest fixture_path fixture_json compatibility max_bytes)

  @type config :: %{required(:mode) => :live | :replay, optional(atom()) => term()}

  @doc "Loads and verifies replay data from trusted registration metadata."
  @spec resolve(map() | nil, keyword()) :: {:ok, config()} | {:error, term()}
  def resolve(environment, opts \\ [])

  def resolve(nil, _opts), do: {:ok, live()}

  def resolve(%{registration: registration}, opts) do
    registration.metadata
    |> metadata_value("jido_console.replay")
    |> resolve_metadata(opts)
  end

  def resolve(_environment, _opts), do: {:error, :invalid_replay_profile_environment}

  @doc "Starts one isolated player for a cell."
  @spec open(config()) :: {:ok, Recorder.controller() | nil} | {:error, term()}
  def open(%{mode: :live}), do: {:ok, nil}

  def open(%{mode: :replay} = replay) do
    Recorder.start_replay(replay.fixture, compatibility: replay.compatibility)
  end

  @doc "Adds replay-only capabilities to normal sequence options."
  @spec put_runtime(keyword(), Recorder.controller() | nil) :: keyword()
  def put_runtime(opts, nil), do: opts

  def put_runtime(opts, player) do
    Keyword.put(opts, :capabilities, ReplayCapabilities.replay(player))
  end

  @doc "Returns safe planning provenance."
  @spec projection(config()) :: map()
  defdelegate projection(config), to: ReplayProjection

  @doc "Checks call consumption, updates replay evidence, and makes mismatches fail the cell."
  @spec finalize(map(), config(), Recorder.controller() | nil) :: map()
  def finalize(result, %{mode: :live}, nil), do: result

  def finalize(result, %{mode: :replay} = replay, player) do
    finish = Recorder.finish(player)
    provenance = Recorder.provenance(player)
    result_mismatch = find_mismatch(result.error)
    interrupted = get_in(result, [:execution, :status]) == :cancelled and is_nil(result_mismatch) and finish != :ok
    mismatch = result_mismatch || if(interrupted, do: nil, else: find_mismatch(finish))
    stop(player)

    projection = %{
      mode: :replay,
      status: replay_status(mismatch, interrupted),
      fixture_schema: replay.fixture.version,
      fixture_digest: replay.fixture.digest,
      recorded_evidence: true,
      matched_calls: provenance["matched_calls"],
      total_calls: provenance["total_calls"]
    }

    projection = if mismatch, do: Map.put(projection, :mismatch, mismatch), else: projection
    result = if mismatch, do: fail_result(result, mismatch), else: result
    Contract.case_result!(Map.put(result, :capability_replay, projection))
  end

  @doc "Stops an unused player after a start failure."
  @spec stop(Recorder.controller() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(player) do
    if Process.alive?(player), do: GenServer.stop(player, :normal)
    :ok
  end

  defp resolve_metadata(nil, _opts), do: {:ok, live()}

  defp resolve_metadata(metadata, opts) when is_map(metadata) do
    supplied = stringify_keys(metadata)
    unknown = Map.keys(supplied) -- @config_keys
    metadata = Map.merge(%{"fixture_path" => nil, "fixture_json" => nil}, supplied)

    with [] <- unknown,
         "replay" <- metadata["mode"],
         {:ok, limit} <- byte_limit(metadata["max_bytes"], opts),
         {:ok, json} <- fixture_json(metadata, limit),
         {:ok, fixture} <- Fixture.decode_json(json),
         :ok <- pinned_digest(metadata["fixture_digest"], fixture.digest),
         {:ok, compatibility} <- compatibility(metadata["compatibility"]),
         {:ok, probe} <- Recorder.start_replay(fixture, compatibility: compatibility) do
      stop(probe)

      {:ok,
       %{
         mode: :replay,
         fixture: fixture,
         compatibility: compatibility
       }}
    else
      values when is_list(values) -> {:error, {:unknown_replay_profile_keys, Enum.sort(values)}}
      mode when is_binary(mode) -> {:error, {:invalid_replay_profile_mode, mode}}
      nil -> {:error, {:invalid_replay_profile_mode, nil}}
      {:error, reason} -> {:error, reason}
      invalid -> {:error, {:invalid_replay_profile, invalid}}
    end
  end

  defp resolve_metadata(metadata, _opts), do: {:error, {:invalid_replay_profile, metadata}}

  defp fixture_json(%{"fixture_path" => path, "fixture_json" => nil}, limit) when is_binary(path) and path != "" do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         :ok <- within_limit(stat.size, limit),
         {:ok, json} <- File.read(path),
         :ok <- within_limit(byte_size(json), limit) do
      {:ok, json}
    else
      false -> {:error, :replay_fixture_not_regular}
      {:error, {:replay_fixture_too_large, _size, _limit} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:replay_fixture_unavailable, reason}}
    end
  end

  defp fixture_json(%{"fixture_path" => nil, "fixture_json" => json}, limit) when is_binary(json) do
    with :ok <- within_limit(byte_size(json), limit), do: {:ok, json}
  end

  defp fixture_json(%{"fixture_path" => path, "fixture_json" => json}, _limit)
       when not is_nil(path) and not is_nil(json),
       do: {:error, :multiple_replay_fixture_sources}

  defp fixture_json(_metadata, _limit), do: {:error, :missing_replay_fixture_source}

  defp byte_limit(value, opts) do
    requested = value || @default_max_bytes
    ceiling = Keyword.get(opts, :max_replay_fixture_bytes, @absolute_max_bytes)

    if valid_limit?(requested) and valid_limit?(ceiling),
      do: {:ok, min(requested, ceiling)},
      else: {:error, {:invalid_replay_fixture_limit, value || ceiling}}
  end

  defp within_limit(size, limit) when size <= limit, do: :ok
  defp within_limit(size, limit), do: {:error, {:replay_fixture_too_large, size, limit}}

  defp valid_limit?(value), do: is_integer(value) and value > 0 and value <= @absolute_max_bytes

  defp pinned_digest(digest, actual) when is_binary(digest) do
    with :ok <- EnvironmentContract.validate_digest(digest, []),
         true <- digest == actual do
      :ok
    else
      false -> {:error, {:replay_fixture_digest_mismatch, digest, actual}}
      {:error, reason} -> {:error, {:invalid_replay_fixture_digest, reason}}
    end
  end

  defp pinned_digest(digest, _actual), do: {:error, {:invalid_replay_fixture_digest, digest}}

  defp compatibility(nil), do: {:ok, %{}}

  defp compatibility(value) when is_map(value) do
    value = stringify_keys(value)

    case EnvironmentContract.validate_safe_map(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_replay_compatibility, reason}}
    end
  end

  defp compatibility(value), do: {:error, {:invalid_replay_compatibility, value}}

  defp find_mismatch(nil), do: nil

  defp find_mismatch({:capability_replay_mismatch, expected, actual}) do
    %{
      kind: :changed_or_out_of_order,
      expected: call_summary(expected),
      actual: call_summary(actual)
    }
  end

  defp find_mismatch({:capability_replay_missing_call, actual}) do
    %{kind: :missing_call, actual: call_summary(actual)}
  end

  defp find_mismatch({:capability_replay_extra_calls, index, remaining}) do
    %{kind: :extra_calls, index: index, remaining: remaining}
  end

  defp find_mismatch(["capability_replay_mismatch", expected, actual]),
    do: find_mismatch({:capability_replay_mismatch, expected, actual})

  defp find_mismatch(["capability_replay_missing_call", actual]),
    do: find_mismatch({:capability_replay_missing_call, actual})

  defp find_mismatch(["capability_replay_extra_calls", index, remaining]),
    do: find_mismatch({:capability_replay_extra_calls, index, remaining})

  defp find_mismatch(%{} = value) do
    value
    |> Map.values()
    |> Enum.find_value(&find_mismatch/1)
  end

  defp find_mismatch(value) when is_tuple(value), do: value |> Tuple.to_list() |> find_mismatch()
  defp find_mismatch(value) when is_list(value), do: Enum.find_value(value, &find_mismatch/1)
  defp find_mismatch(_value), do: nil

  defp call_summary(value) when is_map(value) do
    value
    |> stringify_keys()
    |> Map.take(~w(index class action occurrence))
  end

  defp call_summary(_value), do: %{}

  defp fail_result(result, mismatch) do
    result
    |> put_in([:execution, :status], :error)
    |> Map.put(:evaluation, ResultValue.evaluation([], :error))
    |> Map.put(:error, ResultValue.error({:capability_replay_failed, mismatch}))
  end

  defp replay_status(_mismatch, true), do: :cancelled
  defp replay_status(nil, false), do: :matched
  defp replay_status(_mismatch, false), do: :mismatch

  defp live, do: %{mode: :live}

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, :jido_console_replay))
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
