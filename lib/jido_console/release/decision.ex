defmodule Jido.Console.Release.Decision do
  @moduledoc """
  Derives the release decision from explicit proof records.

  A decision is blocked when required proof is missing or invalid. It fails
  when a valid proof reports failure or an open critical defect. Only a
  complete set of passing proofs produces a passing decision.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.{Channel, Identity}

  @epics Enum.map(1..28, fn index ->
           "jido_console-m1e" <> String.pad_leading(Integer.to_string(index), 2, "0")
         end)

  @channels Channel.channels()
  @allowed_options [:reviews, :channels, :critical_defects, :decided_on, :evidence_revision, :reviewer]
  @schema Zoi.struct(
            __MODULE__,
            %{
              status: Zoi.enum([:pass, :fail, :blocked]),
              version: Zoi.string(),
              reviews: Zoi.any(),
              channels: Zoi.any(),
              critical_defects: Zoi.any(),
              blocking_reasons: Zoi.array(),
              failures: Zoi.array(),
              decided_on: Zoi.string(),
              evidence_revision: Zoi.string(),
              reviewer: Zoi.string()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @opaque t :: %__MODULE__{
            status: :pass | :fail | :blocked,
            version: String.t(),
            reviews: term(),
            channels: term(),
            critical_defects: term(),
            blocking_reasons: [term()],
            failures: [term()],
            decided_on: String.t(),
            evidence_revision: String.t(),
            reviewer: String.t()
          }

  @type publication_authority :: %{
          required(:version) => String.t(),
          required(:decision) => String.t(),
          required(:channels) => [String.t()]
        }

  @doc "Returns the Milestone 1 epic identifiers that require proof."
  @spec epics() :: [String.t()]
  def epics, do: @epics

  @doc "Derives a release decision from explicit review, channel, and defect proofs."
  @spec record(keyword()) :: {:ok, t()} | {:error, term()}
  def record(opts \\ []) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, metadata} <- metadata(opts) do
      reviews = Keyword.get(opts, :reviews, :missing)
      channels = Keyword.get(opts, :channels, :missing)
      critical_defects = Keyword.get(opts, :critical_defects, :missing)

      evaluation = evaluate(reviews, channels, critical_defects)

      {:ok,
       struct!(
         __MODULE__,
         Map.merge(metadata, %{
           status: evaluation.status,
           version: evaluation.version,
           reviews: reviews,
           channels: channels,
           critical_defects: critical_defects,
           blocking_reasons: evaluation.blocking_reasons,
           failures: evaluation.failures
         })
       )}
    end
  end

  @doc "Validates that a decision still matches its proof records."
  @spec validate(term()) :: :ok | {:error, :invalid_release_decision}
  def validate(%__MODULE__{} = decision) do
    evaluation = evaluate(decision.reviews, decision.channels, decision.critical_defects)

    if decision.status == evaluation.status and
         decision.version == evaluation.version and
         decision.blocking_reasons == evaluation.blocking_reasons and
         decision.failures == evaluation.failures and
         valid_metadata?(decision) do
      :ok
    else
      {:error, :invalid_release_decision}
    end
  end

  def validate(_decision), do: {:error, :invalid_release_decision}

  @doc "Projects publication data only from a validated passing decision."
  @spec authorize_publication(term()) ::
          {:ok, publication_authority()}
          | {:error, :invalid_release_decision | {:release_decision_not_passed, :fail | :blocked}}
  def authorize_publication(%__MODULE__{} = decision) do
    with :ok <- validate(decision) do
      case decision.status do
        :pass ->
          {:ok,
           %{
             version: decision.version,
             decision: "pass",
             channels: Enum.map(@channels, &Atom.to_string/1)
           }}

        status ->
          {:error, {:release_decision_not_passed, status}}
      end
    end
  end

  def authorize_publication(_decision), do: {:error, :invalid_release_decision}

  @doc "Returns the derived decision status."
  @spec status(t()) :: :pass | :fail | :blocked
  def status(%__MODULE__{status: status}), do: status

  @doc "Returns the release version proved by the channel records."
  @spec version(t()) :: String.t()
  def version(%__MODULE__{version: version}), do: version

  @doc "Encodes a validated decision as a portable evidence record."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = decision) do
    :ok = validate(decision)

    %{
      "schema" => "jido.release-decision",
      "schema_version" => 1,
      "version" => decision.version,
      "decision" => Atom.to_string(decision.status),
      "decided_on" => decision.decided_on,
      "evidence_revision" => decision.evidence_revision,
      "reviewer" => decision.reviewer,
      "critical_defects" => portable_list(decision.critical_defects),
      "durable_session_recovery" => false,
      "epics" => portable_reviews(decision.reviews),
      "channels" => portable_list(decision.channels),
      "blocking_reasons" => Enum.map(decision.blocking_reasons, &inspect/1),
      "failures" => Enum.map(decision.failures, &inspect/1),
      "known_limits" => [
        "macOS ARM64 only",
        "Ollama remains beta",
        "No durable session recovery"
      ],
      "repair" => "Supply complete passing proof and close all critical defects before publication.",
      "summary" => Redaction.redact("v0.1 #{decision.status} decision recorded without publication")
    }
  end

  defp validate_options(opts) do
    case Keyword.keys(opts) -- @allowed_options do
      [] -> :ok
      unsupported -> {:error, {:unsupported_decision_inputs, unsupported}}
    end
  end

  defp metadata(opts) do
    metadata = %{
      decided_on: Keyword.get(opts, :decided_on, Date.to_iso8601(Date.utc_today())),
      evidence_revision: Keyword.get(opts, :evidence_revision, "milestone-1"),
      reviewer: Keyword.get(opts, :reviewer, "jido_console-m1e29")
    }

    if Enum.all?(Map.values(metadata), &(is_binary(&1) and &1 != "")) do
      {:ok, metadata}
    else
      {:error, :invalid_decision_metadata}
    end
  end

  defp valid_metadata?(decision) do
    Enum.all?(
      [decision.decided_on, decision.evidence_revision, decision.reviewer],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp evaluate(reviews, channels, critical_defects) do
    {review_blockers, review_failures} = evaluate_reviews(reviews)
    {channel_blockers, channel_failures, version} = evaluate_channels(channels)
    {defect_blockers, defect_failures} = evaluate_critical_defects(critical_defects)

    blocking_reasons = review_blockers ++ channel_blockers ++ defect_blockers
    failures = review_failures ++ channel_failures ++ defect_failures

    status =
      cond do
        failures != [] -> :fail
        blocking_reasons != [] -> :blocked
        true -> :pass
      end

    %{
      status: status,
      version: version,
      blocking_reasons: blocking_reasons,
      failures: failures
    }
  end

  defp evaluate_reviews(:missing), do: {[{:missing_proof_set, :reviews}], []}

  defp evaluate_reviews(reviews) when is_map(reviews) do
    keys = Map.keys(reviews)
    missing = @epics -- keys
    unexpected = keys -- @epics

    invalid =
      @epics
      |> Enum.filter(&Map.has_key?(reviews, &1))
      |> Enum.reject(&valid_review?(Map.fetch!(reviews, &1)))

    failures =
      for id <- @epics,
          Map.has_key?(reviews, id),
          valid_review?(Map.fetch!(reviews, id)),
          Map.fetch!(reviews, id)["result"] == "fail",
          do: {:epic_review_failed, id}

    blockers =
      Enum.map(missing, &{:missing_epic_review, &1}) ++
        Enum.map(unexpected, &{:unexpected_epic_review, &1}) ++
        Enum.map(invalid, &{:invalid_epic_review, &1})

    {blockers, failures}
  end

  defp evaluate_reviews(_reviews), do: {[{:invalid_proof_set, :reviews}], []}

  defp valid_review?(%{"result" => result, "proof" => proof}) do
    result in ["pass", "fail"] and is_binary(proof) and String.trim(proof) != ""
  end

  defp valid_review?(_review), do: false

  defp evaluate_channels(:missing), do: {[{:missing_proof_set, :channels}], [], Identity.version()}

  defp evaluate_channels(channels) when is_list(channels) do
    names = Enum.map(channels, &channel_name/1)
    expected_names = Enum.map(@channels, &Atom.to_string/1)
    missing = expected_names -- names
    unexpected = names -- expected_names
    duplicates = names -- Enum.uniq(names)

    validations =
      Enum.map(@channels, fn channel ->
        result = Enum.find(channels, &(channel_name(&1) == Atom.to_string(channel)))
        {channel, result, if(result, do: Channel.validate_result(result, channel), else: :missing)}
      end)

    invalid = for {channel, _result, {:error, _reason}} <- validations, do: channel

    valid_results =
      for {_channel, result, :ok} <- validations,
          do: result

    identities = valid_results |> Enum.map(& &1["payload_identity"]) |> Enum.uniq()

    identity_failure =
      if length(valid_results) == length(@channels) and length(identities) != 1,
        do: [{:channel_identity_mismatch, Enum.map(valid_results, & &1["channel"])}],
        else: []

    failures =
      for(result <- valid_results, result["status"] == "fail", do: {:channel_failed, result["channel"]}) ++
        identity_failure

    blockers =
      Enum.map(missing, &{:missing_channel_proof, &1}) ++
        Enum.map(unexpected, &{:unexpected_channel_proof, &1}) ++
        Enum.map(duplicates, &{:duplicate_channel_proof, &1}) ++
        Enum.map(invalid, &{:invalid_channel_proof, &1})

    version =
      case identities do
        [%{"version" => version}] when is_binary(version) and version != "" -> version
        _other -> Identity.version()
      end

    {blockers, failures, version}
  end

  defp evaluate_channels(_channels), do: {[{:invalid_proof_set, :channels}], [], Identity.version()}

  defp channel_name(%{"channel" => name}) when is_binary(name), do: name
  defp channel_name(_result), do: :invalid

  defp evaluate_critical_defects(:missing), do: {[{:missing_proof_set, :critical_defects}], []}

  defp evaluate_critical_defects(defects) when is_list(defects) do
    invalid = Enum.reject(defects, &valid_critical_defect?/1)

    ids =
      for %{"id" => id} = defect <- defects,
          valid_critical_defect?(defect),
          do: id

    duplicates = ids -- Enum.uniq(ids)

    failures =
      for %{"id" => id, "status" => "open"} = defect <- defects,
          valid_critical_defect?(defect),
          do: {:open_critical_defect, id}

    blockers =
      Enum.map(invalid, &{:invalid_critical_defect, inspect(&1)}) ++
        Enum.map(duplicates, &{:duplicate_critical_defect, &1})

    {blockers, failures}
  end

  defp evaluate_critical_defects(_defects), do: {[{:invalid_proof_set, :critical_defects}], []}

  defp valid_critical_defect?(%{
         "id" => id,
         "severity" => "critical",
         "status" => status,
         "proof" => proof
       }) do
    is_binary(id) and String.trim(id) != "" and status in ["open", "closed"] and
      is_binary(proof) and String.trim(proof) != ""
  end

  defp valid_critical_defect?(_defect), do: false

  defp portable_reviews(reviews) when is_map(reviews) do
    Enum.map(@epics, fn id ->
      case Map.fetch(reviews, id) do
        {:ok, review} when is_map(review) -> Map.put(review, "id", id)
        _other -> %{"id" => id, "result" => "missing", "proof" => nil}
      end
    end)
  end

  defp portable_reviews(_reviews), do: []

  defp portable_list(value) when is_list(value), do: value
  defp portable_list(_value), do: []
end
