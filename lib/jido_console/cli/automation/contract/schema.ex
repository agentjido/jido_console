defmodule Jido.Console.Automation.Contract.Schema do
  @moduledoc """
  Versioned schemas for automation JSONL records and run artifacts.

  Producers use strict schemas. A version 1 reader can use the reader functions
  to ignore unknown optional fields. Extension data is valid only below an
  `extensions` map. Each extension key must be a namespaced identifier such as
  `acme.metrics`.
  """

  @doc "Returns the strict version 1 case-result schema."
  @spec case_result_schema() :: Zoi.schema()
  def case_result_schema, do: case_result_schema(:error)

  @doc "Returns the strict version 1 run-manifest schema."
  @spec manifest_schema() :: Zoi.schema()
  def manifest_schema, do: manifest_schema(:error)

  @doc "Returns the strict version 1 run-summary schema."
  @spec summary_schema() :: Zoi.schema()
  def summary_schema, do: summary_schema(:error)

  @doc "Returns the strict version 1 run-lifecycle schema."
  @spec lifecycle_schema() :: Zoi.schema()
  def lifecycle_schema, do: lifecycle_schema(:error)

  @doc "Returns the strict turn schema used by case-result version 1."
  @spec turn_schema() :: Zoi.schema()
  def turn_schema, do: turn_schema(:error)

  @doc "Returns the strict execution schema used by case-result version 1."
  @spec execution_schema() :: Zoi.schema()
  def execution_schema, do: execution_schema(:error)

  @doc "Returns the additive execution-environment schema used by case-result version 1."
  @spec execution_environment_schema() :: Zoi.schema()
  def execution_environment_schema, do: execution_environment_schema(:error)

  @doc "Returns the additive capability-replay evidence schema."
  @spec capability_replay_schema() :: Zoi.schema()
  def capability_replay_schema, do: capability_replay_schema(:error)

  @doc "Returns the additive automation runtime-limit evidence schema."
  @spec runtime_limits_schema() :: Zoi.schema()
  def runtime_limits_schema, do: runtime_limits_schema(:error)

  @doc "Returns the strict cell-evaluation schema used by case-result version 1."
  @spec evaluation_schema() :: Zoi.schema()
  def evaluation_schema, do: evaluation_schema(:error)

  @doc "Returns the strict assertion schema used by turn records."
  @spec assertion_schema() :: Zoi.schema()
  def assertion_schema, do: assertion_schema(:error)

  @doc "Returns the strict usage schema used by case and turn records."
  @spec usage_schema() :: Zoi.schema()
  def usage_schema, do: Zoi.map(non_empty_string(), non_negative_number(), [])

  @doc "Returns the strict portable-error schema used by case and turn records."
  @spec error_schema() :: Zoi.schema()
  def error_schema, do: error_schema(:error)

  @doc "Returns the strict matrix-dimensions schema."
  @spec dimensions_schema() :: Zoi.schema()
  def dimensions_schema, do: dimensions_schema(:error)

  @doc "Returns the strict source-provenance schema."
  @spec sources_schema() :: Zoi.schema()
  def sources_schema, do: sources_schema(:error)

  @doc false
  @spec case_result_schema(:error | :strip) :: Zoi.schema()
  def case_result_schema(keys) when keys in [:error, :strip] do
    object(
      %{
        schema: Zoi.enum(["jido.case-result"]),
        schema_version: Zoi.enum([1]),
        type: Zoi.enum(["case.result"]),
        run_id: non_empty_string(),
        cell_id: non_empty_string(),
        sequence: positive_integer(),
        dimensions: dimensions_schema(keys),
        sources: sources_schema(keys),
        execution: execution_schema(keys),
        execution_environment: execution_environment_schema(keys) |> Zoi.optional(),
        capability_replay: capability_replay_schema(keys) |> Zoi.optional(),
        runtime_limits: runtime_limits_schema(keys) |> Zoi.optional(),
        evaluation: evaluation_schema(keys),
        turns: Zoi.array(turn_schema(keys)),
        usage: usage_schema(),
        error: error_schema(keys) |> Zoi.nullish(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp turn_schema(keys) do
    object(
      %{
        turn_id: non_empty_string(),
        request_id: non_empty_string() |> Zoi.optional(),
        input: Zoi.json(),
        status: atom_enum([:ok, :error, :hibernated, :cancelled]),
        duration_ms: non_negative_integer(),
        response: response_schema(keys) |> Zoi.nullish(),
        evaluation: turn_evaluation_schema(keys),
        observations: observations_schema(keys),
        usage: usage_schema(),
        error: error_schema(keys) |> Zoi.nullish() |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp response_schema(keys) do
    object(
      %{
        content: Zoi.string() |> Zoi.nullish(),
        value: Zoi.json(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp execution_schema(keys) do
    object(
      %{
        status: atom_enum([:ok, :error, :hibernated, :cancelled]),
        started_at: non_empty_string(),
        duration_ms: non_negative_integer(),
        turn_count: non_negative_integer(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp execution_environment_schema(keys) do
    object(
      %{
        status:
          atom_enum([
            :not_requested,
            :resolved,
            :rejected,
            :open_failed,
            :enforced,
            :closed,
            :close_failed,
            :cleanup_failed,
            :recorded
          ]),
        requested: environment_request_schema(keys) |> Zoi.optional(),
        resolved: environment_resolution_schema(keys) |> Zoi.optional(),
        binding: environment_binding_schema(keys) |> Zoi.optional(),
        confirmed: environment_evidence_schema(keys) |> Zoi.optional(),
        lifecycle: environment_lifecycle_schema(keys) |> Zoi.optional()
      },
      keys
    )
  end

  defp capability_replay_schema(keys) do
    object(
      %{
        mode: atom_enum([:live, :replay]),
        status: atom_enum([:not_replayed, :configured, :matched, :mismatch, :cancelled]),
        fixture_schema: positive_integer() |> Zoi.optional(),
        fixture_digest: digest_string() |> Zoi.optional(),
        recorded_evidence: Zoi.boolean(),
        matched_calls: non_negative_integer(),
        total_calls: non_negative_integer(),
        mismatch: replay_mismatch_schema(keys) |> Zoi.optional()
      },
      keys
    )
  end

  defp replay_mismatch_schema(keys) do
    object(
      %{
        kind: atom_enum([:changed_or_out_of_order, :missing_call, :extra_calls]),
        expected: replay_call_schema(keys) |> Zoi.optional(),
        actual: replay_call_schema(keys) |> Zoi.optional(),
        index: positive_integer() |> Zoi.optional(),
        remaining: positive_integer() |> Zoi.optional()
      },
      keys
    )
  end

  defp replay_call_schema(keys) do
    object(
      %{
        index: positive_integer() |> Zoi.optional(),
        class: Zoi.enum(["llm", "operation", "policy", "environment"]) |> Zoi.optional(),
        action: non_empty_string() |> Zoi.optional(),
        occurrence: positive_integer() |> Zoi.optional()
      },
      keys
    )
  end

  defp runtime_limits_schema(keys) do
    object(
      %{
        status: atom_enum([:configured, :within, :exceeded]),
        requested: runtime_limit_values_schema(keys, :requested),
        applied: runtime_limit_values_schema(keys, :applied),
        observed: runtime_limit_observed_schema(keys),
        exceeded: runtime_limit_exceeded_schema(keys) |> Zoi.nullish()
      },
      keys
    )
  end

  defp runtime_limit_values_schema(keys, mode) do
    fields = %{
      max_cells: positive_integer(),
      max_turns_per_cell: positive_integer(),
      cell_timeout_ms: positive_integer(),
      suite_timeout_ms: positive_integer(),
      max_total_tokens: positive_integer(),
      max_total_cost: Zoi.number() |> Zoi.gt(0),
      provider_concurrency: Zoi.map(non_empty_string(), positive_integer(), [])
    }

    fields =
      if mode == :requested, do: Map.new(fields, fn {key, schema} -> {key, Zoi.optional(schema)} end), else: fields

    object(fields, keys)
  end

  defp runtime_limit_observed_schema(keys) do
    object(
      %{
        cells: non_negative_integer(),
        turns: non_negative_integer(),
        duration_ms: non_negative_integer(),
        total_tokens: non_negative_integer(),
        total_cost: non_negative_number()
      },
      keys
    )
  end

  defp runtime_limit_exceeded_schema(keys) do
    object(
      %{
        kind:
          atom_enum([
            :max_cells,
            :max_turns_per_cell,
            :cell_timeout,
            :suite_timeout,
            :model_turns,
            :turn_timeout,
            :capability_timeout,
            :sequence_timeout,
            :total_tokens,
            :total_cost,
            :environment
          ]),
        limit: non_negative_number(),
        observed: non_negative_number()
      },
      keys
    )
  end

  defp environment_request_schema(keys) do
    object(
      %{
        profile_id: non_empty_string(),
        capability_ids: Zoi.array(non_empty_string()),
        policy_digest: digest_string()
      },
      keys
    )
  end

  defp environment_resolution_schema(keys) do
    object(
      %{
        profile_id: non_empty_string(),
        profile_digest: digest_string(),
        registration_fingerprint: digest_string()
      },
      keys
    )
  end

  defp environment_binding_schema(keys) do
    object(
      %{
        fingerprint: digest_string(),
        revision: non_negative_integer(),
        state: atom_enum([:opened, :available, :acquired, :closed, :cleaned])
      },
      keys
    )
  end

  defp environment_evidence_schema(keys) do
    object(
      %{
        status: atom_enum([:confirmed, :partial, :unknown, :unsupported]),
        adapter_id: non_empty_string(),
        backend: non_empty_string(),
        isolation: atom_enum([:unknown, :none, :process, :container, :vm, :microvm]),
        network: atom_enum([:unknown, :disabled, :restricted, :unrestricted]),
        workspace: atom_enum([:unknown, :ephemeral, :persistent, :isolated_copy]),
        image_digest: digest_string() |> Zoi.nullish(),
        applied_limits: Zoi.json(),
        checkpoint: Zoi.json(),
        observed_at_ms: non_negative_integer(),
        attestation_ref: Zoi.string() |> Zoi.nullish()
      },
      keys
    )
  end

  defp environment_lifecycle_schema(keys) do
    observation = atom_enum([:confirmed, :failed, :not_observed, :not_applied, :unknown])

    object(
      %{
        session_status: atom_enum([:opened, :available, :checkpointed, :restored, :forked, :cleaned]),
        checkpoint: observation,
        restore: observation,
        fork: observation,
        close: observation,
        cleanup: observation,
        checkpoint_facts: environment_checkpoint_schema(keys) |> Zoi.nullish()
      },
      keys
    )
  end

  defp environment_checkpoint_schema(keys) do
    object(
      %{
        fingerprint: digest_string(),
        binding_revision: non_negative_integer(),
        evidence_digest: digest_string(),
        preserves: Zoi.json(),
        forkable: Zoi.boolean(),
        created_at_ms: non_negative_integer()
      },
      keys
    )
  end

  defp evaluation_schema(keys) do
    object(
      %{
        status: atom_enum([:passed, :failed, :unscored, :not_run]),
        assertion_count: non_negative_integer(),
        failed_assertion_count: non_negative_integer(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp turn_evaluation_schema(keys) do
    object(
      %{
        status: atom_enum([:passed, :failed, :unscored, :not_run]),
        assertions: Zoi.array(assertion_schema(keys)),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp assertion_schema(keys) do
    name =
      Zoi.union([
        atom_enum([:contains, :equals, :operation_called, :eval_case]),
        extension_id()
      ])

    object(
      %{
        name: name,
        status: atom_enum([:passed, :failed]),
        expected: Zoi.json() |> Zoi.optional(),
        actual: Zoi.json() |> Zoi.optional(),
        message: Zoi.string() |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp observations_schema(keys) do
    object(
      %{
        operation_calls: Zoi.array(Zoi.string()) |> Zoi.optional(),
        event_count: non_negative_integer() |> Zoi.optional(),
        journal_intents: non_negative_integer() |> Zoi.optional(),
        journal_results: non_negative_integer() |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp error_schema(keys) do
    object(
      %{
        category: non_empty_string(),
        message: non_empty_string(),
        phase: Zoi.string() |> Zoi.optional(),
        field: Zoi.string() |> Zoi.optional(),
        value: Zoi.json() |> Zoi.optional(),
        details: Zoi.json() |> Zoi.optional(),
        errors: Zoi.array(error_item_schema(keys)) |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp error_item_schema(keys) do
    object(
      %{
        category: non_empty_string(),
        message: non_empty_string(),
        phase: Zoi.string() |> Zoi.optional(),
        field: Zoi.string() |> Zoi.optional(),
        value: Zoi.json() |> Zoi.optional(),
        details: Zoi.json() |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp dimensions_schema(keys) do
    object(
      %{
        suite_id: non_empty_string(),
        agent_key: non_empty_string(),
        agent_spec_id: non_empty_string(),
        scenario_id: non_empty_string(),
        model_key: non_empty_string(),
        model_ref: non_empty_string(),
        trial: positive_integer(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp sources_schema(keys) do
    object(
      %{
        agent_file: non_empty_string(),
        scenario_file: non_empty_string(),
        agent_sha256: non_empty_string(),
        effective_agent_sha256: non_empty_string(),
        scenario_sha256: non_empty_string(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  @doc false
  @spec manifest_schema(:error | :strip) :: Zoi.schema()
  def manifest_schema(keys) when keys in [:error, :strip] do
    object(
      %{
        schema: Zoi.enum(["jido.run-manifest"]),
        schema_version: Zoi.enum([1]),
        run_id: non_empty_string(),
        suite_id: non_empty_string(),
        suite_file: non_empty_string(),
        suite_sha256: non_empty_string(),
        versions: versions_schema(keys),
        matrix: matrix_schema(keys),
        runtime_limits: runtime_limits_schema(keys) |> Zoi.optional(),
        cells: Zoi.array(manifest_cell_schema(keys)),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp versions_schema(keys) do
    object(
      %{
        jido_console: non_empty_string(),
        jidoka: non_empty_string(),
        elixir: non_empty_string(),
        otp: non_empty_string()
      },
      keys
    )
  end

  defp matrix_schema(keys) do
    object(
      %{
        agents: Zoi.array(non_empty_string()),
        models: Zoi.array(non_empty_string()),
        scenarios: Zoi.array(non_empty_string()),
        repeats: positive_integer(),
        cells: non_negative_integer()
      },
      keys
    )
  end

  defp manifest_cell_schema(keys) do
    object(
      %{
        sequence: positive_integer(),
        cell_id: non_empty_string(),
        dimensions: dimensions_schema(keys),
        sources: sources_schema(keys),
        execution_environment: execution_environment_schema(keys) |> Zoi.optional(),
        capability_replay: capability_replay_schema(keys) |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  @doc false
  @spec summary_schema(:error | :strip) :: Zoi.schema()
  def summary_schema(keys) when keys in [:error, :strip] do
    object(
      %{
        schema: Zoi.enum(["jido.run-summary"]),
        schema_version: Zoi.enum([1]),
        run_id: non_empty_string(),
        suite_id: non_empty_string(),
        status: atom_enum([:passed, :failed, :cancelled]),
        planned: non_negative_integer(),
        completed: non_negative_integer(),
        counts: counts_schema(keys),
        duration_ms: non_negative_integer(),
        not_started: Zoi.array(non_empty_string()) |> Zoi.optional(),
        runtime_limits: runtime_limits_schema(keys) |> Zoi.optional(),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  @doc false
  @spec lifecycle_schema(:error | :strip) :: Zoi.schema()
  def lifecycle_schema(keys) when keys in [:error, :strip] do
    object(
      %{
        schema: Zoi.enum(["jido.run-lifecycle"]),
        schema_version: Zoi.enum([1]),
        run_id: non_empty_string(),
        suite_id: non_empty_string(),
        status: atom_enum([:running, :completed, :failed, :cancelled, :incomplete]),
        started_at: non_empty_string(),
        finished_at: non_empty_string() |> Zoi.nullish(),
        planned: Zoi.array(lifecycle_cell_schema(keys)),
        started: Zoi.array(lifecycle_cell_schema(keys)),
        completed: Zoi.array(lifecycle_cell_schema(keys)),
        failed: Zoi.array(lifecycle_cell_schema(keys)),
        cancelled: Zoi.array(lifecycle_cell_schema(keys)),
        missing: Zoi.array(lifecycle_cell_schema(keys)),
        primary_error: error_schema(keys) |> Zoi.nullish(),
        finalization_errors: Zoi.array(error_schema(keys))
      },
      keys
    )
  end

  defp lifecycle_cell_schema(keys) do
    object(
      %{
        cell_id: non_empty_string(),
        sequence: positive_integer()
      },
      keys
    )
  end

  defp counts_schema(keys) do
    object(
      %{
        passed: non_negative_integer(),
        failed: non_negative_integer(),
        errors: non_negative_integer(),
        unscored: non_negative_integer(),
        cancelled: non_negative_integer() |> Zoi.optional()
      },
      keys
    )
  end

  defp extensions_schema do
    Zoi.map(extension_id(), Zoi.json(), [])
  end

  defp extension_id do
    Zoi.string() |> Zoi.regex(Regex.compile!("^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$"))
  end

  defp non_empty_string, do: Zoi.string() |> Zoi.regex(Regex.compile!("\\S"))
  defp digest_string, do: Zoi.string() |> Zoi.regex(Regex.compile!("^sha256:[0-9a-f]{64}$"))
  defp positive_integer, do: Zoi.integer() |> Zoi.positive()
  defp non_negative_integer, do: Zoi.integer() |> Zoi.gte(0)
  defp non_negative_number, do: Zoi.number() |> Zoi.gte(0)

  defp atom_enum(values) do
    values
    |> Enum.map(&{&1, Atom.to_string(&1)})
    |> Zoi.enum(coerce: true)
  end

  defp object(fields, keys), do: Zoi.map(fields, coerce: true, unrecognized_keys: keys)
end
