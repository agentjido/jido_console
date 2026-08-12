defmodule Jido.Cli.Automation.Contract do
  @moduledoc """
  Versioned schemas for automation JSONL records and run artifacts.

  Producers use strict schemas. A version 1 reader can use the reader functions
  to ignore unknown optional fields. Extension data is valid only below an
  `extensions` map. Each extension key must be a namespaced identifier such as
  `acme.metrics`.
  """

  @type kind :: :case_result | :manifest | :summary
  @type validation_error :: {:invalid_automation_contract, kind(), term()}

  @doc "Returns the strict version 1 case-result schema."
  @spec case_result_schema() :: Zoi.schema()
  def case_result_schema, do: case_result_schema(:error)

  @doc "Returns the strict version 1 run-manifest schema."
  @spec manifest_schema() :: Zoi.schema()
  def manifest_schema, do: manifest_schema(:error)

  @doc "Returns the strict version 1 run-summary schema."
  @spec summary_schema() :: Zoi.schema()
  def summary_schema, do: summary_schema(:error)

  @doc "Returns the strict turn schema used by case-result version 1."
  @spec turn_schema() :: Zoi.schema()
  def turn_schema, do: turn_schema(:error)

  @doc "Returns the strict execution schema used by case-result version 1."
  @spec execution_schema() :: Zoi.schema()
  def execution_schema, do: execution_schema(:error)

  @doc "Returns the additive execution-environment schema used by case-result version 1."
  @spec execution_environment_schema() :: Zoi.schema()
  def execution_environment_schema, do: execution_environment_schema(:error)

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

  @doc "Validates and normalizes one producer case-result record."
  @spec validate_case_result(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_case_result(value), do: validate(:case_result, case_result_schema(:error), value)

  @doc "Validates and normalizes one producer run manifest."
  @spec validate_manifest(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_manifest(value), do: validate(:manifest, manifest_schema(:error), value)

  @doc "Validates and normalizes one producer run summary."
  @spec validate_summary(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_summary(value), do: validate(:summary, summary_schema(:error), value)

  @doc "Reads a version 1 case result and ignores unknown optional fields."
  @spec read_case_result(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_case_result(value), do: validate(:case_result, case_result_schema(:strip), value)

  @doc "Reads a version 1 run manifest and ignores unknown optional fields."
  @spec read_manifest(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_manifest(value), do: validate(:manifest, manifest_schema(:strip), value)

  @doc "Reads a version 1 run summary and ignores unknown optional fields."
  @spec read_summary(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_summary(value), do: validate(:summary, summary_schema(:strip), value)

  @doc "Validates a case-result record and raises for an internal producer bug."
  @spec case_result!(term()) :: map()
  def case_result!(value), do: validate!(validate_case_result(value))

  @doc "Validates a run manifest and raises for an internal producer bug."
  @spec manifest!(term()) :: map()
  def manifest!(value), do: validate!(validate_manifest(value))

  @doc "Validates a run summary and raises for an internal producer bug."
  @spec summary!(term()) :: map()
  def summary!(value), do: validate!(validate_summary(value))

  defp case_result_schema(keys) do
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
            :cleanup_failed
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

  defp manifest_schema(keys) do
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
        cells: Zoi.array(manifest_cell_schema(keys)),
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp versions_schema(keys) do
    object(
      %{
        jido_cli: non_empty_string(),
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
        extensions: extensions_schema() |> Zoi.optional()
      },
      keys
    )
  end

  defp summary_schema(keys) do
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
        extensions: extensions_schema() |> Zoi.optional()
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
    Zoi.string() |> Zoi.regex(~r/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$/)
  end

  defp non_empty_string, do: Zoi.string() |> Zoi.regex(~r/\S/)
  defp digest_string, do: Zoi.string() |> Zoi.regex(~r/^sha256:[0-9a-f]{64}$/)
  defp positive_integer, do: Zoi.integer() |> Zoi.positive()
  defp non_negative_integer, do: Zoi.integer() |> Zoi.gte(0)
  defp non_negative_number, do: Zoi.number() |> Zoi.gte(0)

  defp atom_enum(values) do
    values
    |> Enum.map(&{&1, Atom.to_string(&1)})
    |> Zoi.enum(coerce: true)
  end

  defp object(fields, keys), do: Zoi.map(fields, coerce: true, unrecognized_keys: keys)

  defp validate(kind, schema, value) do
    with {:ok, portable} <- portable(value),
         {:ok, parsed} <- Zoi.parse(schema, portable),
         {:ok, _json} <- Jason.encode(parsed) do
      {:ok, parsed}
    else
      {:error, reason} -> {:error, {:invalid_automation_contract, kind, reason}}
    end
  end

  defp validate!({:ok, value}), do: value

  defp validate!({:error, reason}) do
    raise ArgumentError, "invalid automation producer data: #{inspect(reason)}"
  end

  defp portable(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp portable(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp portable(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, items} ->
      case portable(item) do
        {:ok, portable_item} -> {:cont, {:ok, [portable_item | items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp portable(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, items} ->
      with {:ok, portable_key} <- portable_key(key),
           false <- Map.has_key?(items, portable_key),
           {:ok, portable_item} <- portable(item) do
        {:cont, {:ok, Map.put(items, portable_key, portable_item)}}
      else
        true -> {:halt, {:error, {:duplicate_json_key, key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp portable(value), do: {:error, {:non_json_value, value}}

  defp portable_key(key) when is_binary(key), do: {:ok, key}
  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(key), do: {:error, {:non_json_map_key, key}}
end
