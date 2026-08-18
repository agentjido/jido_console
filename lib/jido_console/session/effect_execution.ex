defmodule Jido.Console.Session.EffectExecution do
  @moduledoc """
  Durable pre-dispatch reservation and closed restart policy for Jidoka effects.

  The caller supplies the current authoritative Jidoka journal, a journal
  commit function, and the provider or tool dispatch function. This module
  does not use Jidoka runtime internals. An already materialized credential can
  be supplied as `:credential_value`; it remains process-local and is used only
  as a rejection canary for arguments and results.
  """

  alias Jido.Console.Session.AuditProjection
  alias Jido.Console.Session.Durable.{CanonicalJSON, EffectRecord, Record, Value}
  alias Jido.Console.Session.{Generation, Manifest}
  alias Jido.Console.Storage
  alias Jidoka.Effect.{Intent, Journal, Result}

  @max_records 256
  @max_bytes 4 * 1_024 * 1_024
  @terminal_statuses ~w(completed failed cancelled uncertain reconciled abandoned)

  @type authority :: %{
          required(:session_id) => String.t(),
          required(:request_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:result_id) => String.t(),
          required(:required_permission) => String.t(),
          required(:current_manifest) => map(),
          required(:fence) => Generation.t(),
          optional(:permission) => map() | nil,
          optional(:prior_attempt_id) => String.t() | nil
        }

  @doc "Returns the closed Jidoka idempotency-to-replay policy table."
  @spec replay_policy(atom()) :: {:ok, map()} | {:error, term()}
  def replay_policy(idempotency), do: EffectRecord.policy(idempotency)

  @doc "Reserves, fences, dispatches, and records one model or tool effect."
  @spec execute(Intent.t(), authority(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(intent, authority, opts \\ [])

  def execute(%Intent{} = intent, authority, opts) when is_map(authority) do
    with {:ok, context} <- prepare(intent, authority, opts),
         {:ok, reservation} <- reserve(context, opts),
         :ok <- barrier(opts, :after_reservation),
         {:ok, journal, revision} <- journal(opts) do
      continue(context, reservation, journal, revision, opts)
    end
  end

  def execute(_intent, _authority, _opts), do: {:error, :invalid_effect_execution}

  @doc "Returns bounded durable attempts and their latest states without dispatch."
  @spec inspect(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(session_id, effect_id, opts \\ [])

  def inspect(session_id, effect_id, opts) when is_binary(session_id) and is_binary(effect_id) do
    with {:ok, records} <- storage(opts).range(scope_id(session_id, effect_id), read_opts(opts)),
         :ok <- verify_generation_chains(records) do
      attempts =
        records
        |> Enum.map(& &1.record["payload"])
        |> Enum.group_by(& &1["attempt_id"])
        |> Enum.map(fn {attempt_id, payloads} ->
          reservation = Enum.find(payloads, &Map.has_key?(&1, "replay_rule"))
          states = Enum.reject(payloads, &Map.has_key?(&1, "replay_rule"))
          latest = List.last(states)

          %{
            attempt_id: attempt_id,
            reservation: reservation,
            states: states,
            latest_status: latest && latest["status"],
            terminal: latest && latest["status"] in @terminal_statuses
          }
        end)
        |> Enum.sort_by(& &1.attempt_id)

      {:ok, %{session_id: session_id, effect_id: effect_id, attempts: attempts}}
    end
  end

  def inspect(_session_id, _effect_id, _opts), do: {:error, :invalid_effect_inspection}

  @doc "Records an explicit non-dispatch reconciliation decision."
  @spec reconcile(Intent.t(), authority(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(intent, authority, decision, opts \\ [])

  def reconcile(%Intent{} = intent, authority, decision, opts)
      when is_map(authority) and is_map(decision) do
    with {:ok, context} <- prepare(intent, authority, opts),
         {:ok, reservation} <- existing_reservation(context, opts),
         {:ok, journal, revision} <- journal(opts),
         {:ok, payload} <- reconciliation_payload(context, reservation, decision, journal, revision, opts),
         {:ok, transition} <- append_transition(context, payload, "reconcile", opts) do
      {:ok, %{status: String.to_existing_atom(payload["status"]), transition: transition}}
    end
  end

  def reconcile(_intent, _authority, _decision, _opts), do: {:error, :invalid_effect_reconciliation}

  defp prepare(intent, authority, opts) do
    with {:ok, policy} <- EffectRecord.policy(intent.idempotency),
         {:ok, context} <- validate_authority(intent, authority, policy),
         {:ok, effective_arguments} <- portable_value(intent.payload),
         :ok <- Value.validate(effective_arguments),
         :ok <- AuditProjection.scan(effective_arguments, forbidden_values(opts)),
         {:ok, compatible} <-
           Manifest.compatibility(
             context.session_id,
             context.request_id,
             context.current_manifest,
             opts
           ),
         {:ok, manifest_digest} <- Manifest.identity(compatible.manifest),
         {:ok, arguments_digest} <- Manifest.identity(effective_arguments) do
      {:ok,
       context
       |> Map.put(:manifest, compatible.manifest)
       |> Map.put(:manifest_digest, manifest_digest)
       |> Map.put(:effective_arguments, effective_arguments)
       |> Map.put(:arguments_digest, arguments_digest)}
    end
  end

  defp validate_authority(intent, authority, policy) do
    fence = fetch(authority, :fence)
    permission = fetch(authority, :permission)
    required_permission = fetch(authority, :required_permission)

    context = %{
      intent: intent,
      policy: policy,
      session_id: fetch(authority, :session_id),
      request_id: fetch(authority, :request_id),
      attempt_id: fetch(authority, :attempt_id),
      prior_attempt_id: fetch(authority, :prior_attempt_id),
      result_id: fetch(authority, :result_id),
      required_permission: required_permission,
      current_manifest: fetch(authority, :current_manifest),
      permission: permission,
      fence: fence,
      operation_prefix:
        fetch(authority, :operation_id) ||
          "effect:#{fetch(authority, :session_id)}:#{intent.id}:#{fetch(authority, :attempt_id)}"
    }

    with :ok <- validate_ids(context),
         :ok <- Generation.validate(fence),
         true <- fence.session_id == context.session_id,
         :ok <- validate_permission(context) do
      {:ok, context}
    else
      false -> {:error, :cross_session_effect_fence}
      {:error, _reason} = error -> error
    end
  end

  defp validate_ids(context) do
    fields = [
      session_id: context.session_id,
      request_id: context.request_id,
      attempt_id: context.attempt_id,
      result_id: context.result_id,
      required_permission: context.required_permission,
      operation_id: context.operation_prefix
    ]

    case Enum.find(fields, fn {_field, value} -> not valid_id?(value) end) do
      nil ->
        if is_map(context.current_manifest), do: :ok, else: {:error, :invalid_effect_current_manifest}

      {field, _value} ->
        {:error, {:invalid_effect_identity, field}}
    end
  end

  defp validate_permission(%{required_permission: "none", permission: nil}), do: :ok

  defp validate_permission(context) when is_map(context.permission) do
    permission = context.permission
    fence = context.fence

    checks = [
      {:decision, fetch(permission, :decision), [:approved, "approved"]},
      {:session_id, fetch(permission, :session_id), context.session_id},
      {:generation, fetch(permission, :generation), fence.generation},
      {:owner_instance_id, fetch(permission, :owner_instance_id), fence.owner_instance_id},
      {:scope, fetch(permission, :scope), context.required_permission},
      {:effect_id, fetch(permission, :effect_id), context.intent.id}
    ]

    case Enum.find(checks, fn
           {:decision, actual, allowed} -> actual not in allowed
           {_field, actual, expected} -> actual != expected
         end) do
      nil ->
        case fetch(permission, :id) do
          value when is_binary(value) and value != "" -> :ok
          _other -> {:error, {:stale_effect_authority, :approval_id}}
        end

      {field, _actual, _expected} ->
        {:error, {:stale_effect_authority, field}}
    end
  end

  defp validate_permission(_context), do: {:error, :effect_permission_required}

  defp reserve(context, opts) do
    payload = reservation_payload(context)

    with {:ok, records} <- effect_records(context, opts) do
      case same_attempt(records, context.attempt_id, "effect_reservation") do
        nil -> append_record(context, "effect_reservation", payload, "reserve", opts)
        %{record: %{"payload" => ^payload}} = existing -> {:ok, %{record: existing.record, duplicate: true}}
        _other -> {:error, {:effect_attempt_conflict, context.attempt_id}}
      end
    end
  end

  defp existing_reservation(context, opts) do
    with {:ok, records} <- effect_records(context, opts) do
      case same_attempt(records, context.attempt_id, "effect_reservation") do
        nil -> {:error, {:effect_reservation_not_found, context.attempt_id}}
        existing -> {:ok, existing.record["payload"]}
      end
    end
  end

  defp reservation_payload(context) do
    manifest = context.manifest

    %{
      "session_id" => context.session_id,
      "request_id" => context.request_id,
      "effect_id" => context.intent.id,
      "attempt_id" => context.attempt_id,
      "prior_attempt_id" => context.prior_attempt_id,
      "result_id" => context.result_id,
      "effect_kind" => Atom.to_string(context.intent.kind),
      "effective_arguments" => context.effective_arguments,
      "arguments_digest" => context.arguments_digest,
      "safety_class" => context.policy.safety_class,
      "replay_rule" => context.policy.replay_rule,
      "required_permission" => context.required_permission,
      "approval_id" => context.permission && fetch(context.permission, :id),
      "turn_manifest_digest" => context.manifest_digest,
      "generation" => context.fence.generation,
      "jidoka_intent_id" => context.intent.id,
      "jidoka_idempotency_key" => context.intent.idempotency_key,
      "credential_reference_id" => manifest["credential_reference_id"],
      "workspace_digest" => manifest["workspace_digest"]
    }
  end

  defp continue(context, reservation, journal, revision, opts) do
    case Journal.result_for(journal, context.intent) do
      %Result{} = result -> reuse_result(context, reservation, journal, revision, result, opts)
      nil -> continue_without_result(context, reservation, journal, revision, opts)
    end
  end

  defp continue_without_result(context, reservation, journal, revision, opts) do
    with {:ok, terminal} <- terminal_state(context, opts),
         {:ok, started?} <- attempt_started?(context, opts) do
      cond do
        terminal != nil ->
          terminal_without_jidoka_result(terminal, reservation, journal)

        started? ->
          stop_started_attempt(context, reservation, journal, revision, opts)

        Journal.intent_recorded?(journal, context.intent) ->
          incomplete(context, reservation, journal, revision, opts)

        true ->
          journal = Journal.put_intent(journal, context.intent)

          with {:ok, revision} <- persist_journal(journal, :intent, opts),
               {:ok, _transition} <-
                 append_transition(context, resolution(context, "intent_recorded", revision), "intent", opts),
               :ok <- barrier(opts, :after_intent) do
            dispatch(context, reservation, journal, revision, opts)
          end
      end
    end
  end

  defp attempt_started?(context, opts) do
    with {:ok, records} <- effect_records(context, opts) do
      {:ok,
       Enum.any?(records, fn item ->
         item.record["record_type"] == "effect_resolution" and
           item.record["payload"]["attempt_id"] == context.attempt_id and
           item.record["payload"]["status"] == "started"
       end)}
    end
  end

  defp stop_started_attempt(context, reservation, journal, revision, opts) do
    action =
      case context.policy.incomplete do
        :dispatch -> :new_attempt
        other -> other
      end

    payload =
      resolution(context, "uncertain", revision, uncertainty_reason: "outcome_unknown_after_start")

    with {:ok, transition} <- append_transition(context, payload, "uncertain", opts) do
      {:ok,
       %{
         status: :uncertain,
         action: action,
         reservation: reservation,
         transition: transition,
         journal: journal,
         dispatched: false
       }}
    end
  end

  defp terminal_state(context, opts) do
    with {:ok, records} <- effect_records(context, opts) do
      terminal =
        records
        |> Enum.filter(fn item ->
          item.record["record_type"] == "effect_resolution" and
            item.record["payload"]["attempt_id"] == context.attempt_id and
            item.record["payload"]["status"] in @terminal_statuses
        end)
        |> List.last()

      {:ok, terminal && terminal.record["payload"]}
    end
  end

  defp terminal_without_jidoka_result(%{"status" => status} = terminal, reservation, journal)
       when status in ["failed", "cancelled", "uncertain", "abandoned"] do
    {:ok,
     %{
       status: String.to_existing_atom(status),
       reservation: reservation,
       transition: terminal,
       journal: journal,
       dispatched: false
     }}
  end

  defp terminal_without_jidoka_result(terminal, _reservation, _journal),
    do: {:error, {:jidoka_result_missing_for_terminal_effect, terminal["status"]}}

  defp incomplete(%{policy: %{incomplete: :dispatch}} = context, reservation, journal, revision, opts) do
    with {:ok, _transition} <-
           append_transition(context, resolution(context, "intent_recorded", revision), "intent", opts),
         :ok <- barrier(opts, :after_intent) do
      dispatch(context, reservation, journal, revision, opts)
    end
  end

  defp incomplete(context, reservation, journal, revision, opts) do
    reason =
      case context.policy.incomplete do
        :uncertain -> "unsafe_outcome_unknown"
        :reconcile -> "external_reconciliation_required"
      end

    payload = resolution(context, "uncertain", revision, uncertainty_reason: reason)

    with {:ok, transition} <- append_transition(context, payload, "uncertain", opts) do
      {:ok,
       %{
         status: :uncertain,
         action: context.policy.incomplete,
         reservation: reservation,
         transition: transition,
         journal: journal,
         dispatched: false
       }}
    end
  end

  defp dispatch(context, reservation, journal, revision, opts) do
    with {:ok, started} <- append_transition(context, resolution(context, "started", revision), "start", opts),
         :ok <- barrier(opts, :after_started),
         {:ok, result} <- call_dispatch(context.intent, opts),
         :ok <- barrier(opts, :after_dispatch),
         :ok <- validate_result(context, result, opts),
         journal = Journal.put_result(journal, result),
         {:ok, revision} <- persist_journal(journal, :result, opts),
         :ok <- barrier(opts, :after_jidoka_result),
         {:ok, result_digest} <- result_digest(result),
         status = if(result.status == :ok, do: "completed", else: "failed"),
         payload = resolution(context, status, revision, result_digest: result_digest),
         {:ok, completed} <- append_transition(context, payload, status, opts),
         :ok <- barrier(opts, :after_console_result) do
      {:ok,
       %{
         status: String.to_existing_atom(status),
         result: result,
         result_digest: result_digest,
         reservation: reservation,
         started: started,
         transition: completed,
         journal: journal,
         jidoka_revision: revision,
         dispatched: true
       }}
    else
      {:error, :sensitive_result_blocked} = error ->
        error

      {:error, {:injected_effect_crash, _boundary}} = error ->
        error

      {:error, {:effect_dispatch_failed, reason}} ->
        record_dispatch_stop(context, "failed", reason, revision, opts)

      {:error, {:effect_dispatch_cancelled, reason}} ->
        record_dispatch_stop(context, "cancelled", reason, revision, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp reuse_result(context, reservation, journal, revision, result, opts) do
    with :ok <- validate_result(context, result, opts),
         {:ok, digest} <- result_digest(result),
         status = if(result.status == :ok, do: "completed", else: "failed"),
         payload = resolution(context, status, revision, result_digest: digest),
         {:ok, transition} <- append_transition(context, payload, status, opts) do
      {:ok,
       %{
         status: :replayed,
         result: result,
         result_digest: digest,
         reservation: reservation,
         transition: transition,
         journal: journal,
         jidoka_revision: revision,
         dispatched: false
       }}
    end
  end

  defp call_dispatch(intent, opts) do
    case Keyword.get(opts, :dispatch) do
      fun when is_function(fun, 1) ->
        case fun.(intent) do
          {:ok, %Result{intent_id: id} = result} when id == intent.id -> {:ok, result}
          {:ok, %Result{}} -> {:error, :jidoka_effect_result_identity_mismatch}
          {:error, reason} -> {:error, {:effect_dispatch_failed, redacted_reason(reason)}}
          {:cancelled, reason} -> {:error, {:effect_dispatch_cancelled, redacted_reason(reason)}}
          _other -> {:error, :invalid_effect_dispatch_result}
        end

      _other ->
        {:error, :effect_dispatch_required}
    end
  end

  defp validate_result(context, %Result{} = result, opts) do
    cond do
      result.intent_id != context.intent.id ->
        {:error, :jidoka_effect_result_identity_mismatch}

      result.kind != context.intent.kind ->
        {:error, :jidoka_effect_result_kind_mismatch}

      true ->
        with :ok <- Value.validate(result.output),
             :ok <- AuditProjection.scan(result.output, forbidden_values(opts)) do
          :ok
        else
          {:error, _redacted} -> {:error, :sensitive_result_blocked}
        end
    end
  end

  defp persist_journal(journal, phase, opts) do
    case Keyword.get(opts, :persist_journal) do
      fun when is_function(fun, 2) ->
        case fun.(journal, phase) do
          {:ok, revision} when is_integer(revision) and revision >= 0 -> {:ok, revision}
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_jidoka_journal_commit}
        end

      _other ->
        {:error, :jidoka_journal_commit_required}
    end
  end

  defp journal(opts) do
    case {Keyword.get(opts, :journal), Keyword.get(opts, :jidoka_revision)} do
      {%Journal{} = journal, revision} when is_integer(revision) and revision >= 0 ->
        {:ok, journal, revision}

      _other ->
        {:error, :authoritative_jidoka_journal_required}
    end
  end

  defp record_dispatch_stop(context, status, reason, revision, opts) do
    payload = resolution(context, status, revision)

    case append_transition(context, payload, status, opts) do
      {:ok, transition} ->
        {:ok, %{status: String.to_existing_atom(status), reason: reason, transition: transition, dispatched: true}}

      {:error, _reason} = error ->
        error
    end
  end

  defp reconciliation_payload(context, reservation, decision, journal, revision, opts) do
    decision_id = fetch(decision, :decision_id)
    outcome = fetch(decision, :outcome)

    cond do
      not valid_id?(decision_id) ->
        {:error, :reconciliation_decision_id_required}

      outcome in [:abandoned, "abandoned", :failed, "failed", :cancelled, "cancelled"] ->
        status = if is_atom(outcome), do: Atom.to_string(outcome), else: outcome
        {:ok, resolution(context, status, revision, decision_id: decision_id)}

      outcome in [:completed, "completed"] ->
        case Journal.result_for(journal, context.intent) do
          %Result{} = result ->
            with :ok <- validate_result(context, result, opts),
                 {:ok, digest} <- result_digest(result) do
              {:ok,
               resolution(context, "reconciled", revision,
                 decision_id: decision_id,
                 result_digest: digest
               )}
            end

          nil ->
            {:error, {:jidoka_result_required_for_reconciliation, reservation["result_id"]}}
        end

      true ->
        {:error, :unsupported_effect_reconciliation}
    end
  end

  defp resolution(context, status, revision, opts \\ []) do
    %{
      "session_id" => context.session_id,
      "effect_id" => context.intent.id,
      "attempt_id" => context.attempt_id,
      "result_id" => context.result_id,
      "status" => status,
      "jidoka_intent_id" => context.intent.id,
      "jidoka_revision" => revision,
      "result_digest" => Keyword.get(opts, :result_digest),
      "decision_id" => Keyword.get(opts, :decision_id),
      "uncertainty_reason" => Keyword.get(opts, :uncertainty_reason)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp append_transition(context, payload, operation_suffix, opts) do
    with {:ok, records} <- effect_records(context, opts) do
      existing =
        Enum.find(records, fn item ->
          item.record["record_type"] == "effect_resolution" and
            item.record["payload"]["attempt_id"] == context.attempt_id and
            item.record["payload"]["status"] == payload["status"]
        end)

      case existing do
        %{record: %{"payload" => ^payload}} -> {:ok, %{record: existing.record, duplicate: true}}
        nil -> append_record(context, "effect_resolution", payload, operation_suffix, opts)
        _other -> {:error, {:effect_transition_conflict, context.attempt_id, payload["status"]}}
      end
    end
  end

  defp append_record(context, type, payload, operation_suffix, opts) do
    with {:ok, records} <- effect_records(context, opts),
         generation_records = Enum.filter(records, &(&1.record["generation"] == context.fence.generation)),
         {sequence, prior} <- next_position(generation_records),
         operation_id = "#{context.operation_prefix}:#{operation_suffix}",
         record =
           Record.new(type, payload,
             record_id: "#{context.session_id}:#{context.intent.id}:#{context.fence.generation}:#{sequence}",
             scope_id: scope_id(context.session_id, context.intent.id),
             generation: context.fence.generation,
             sequence: sequence,
             prior_record_digest: prior
           ),
         :ok <- AuditProjection.scan(record, forbidden_values(opts)),
         fence = Generation.for_operation(context.fence, operation_id),
         {:ok, stored} <-
           storage(opts).append(
             record,
             opts
             |> Keyword.put(:operation_id, operation_id)
             |> Keyword.put(:fence, fence)
           ) do
      {:ok, %{record: record, digest: stored.digest, duplicate: false}}
    end
  end

  defp effect_records(context, opts) do
    with {:ok, records} <-
           storage(opts).range(scope_id(context.session_id, context.intent.id), read_opts(opts)),
         :ok <- verify_generation_chains(records) do
      {:ok, records}
    end
  end

  defp verify_generation_chains(records) do
    records
    |> Enum.group_by(& &1.record["generation"])
    |> Enum.reduce_while(:ok, fn {_generation, chain}, :ok ->
      case Record.verify_chain(chain) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp same_attempt(records, attempt_id, type) do
    Enum.find(records, fn item ->
      item.record["record_type"] == type and item.record["payload"]["attempt_id"] == attempt_id
    end)
  end

  defp next_position([]), do: {0, "genesis"}

  defp next_position(records) do
    latest = List.last(records)
    {latest.record["sequence"] + 1, latest.digest}
  end

  defp result_digest(%Result{} = result) do
    with {:ok, output} <- portable_value(result.output),
         {:ok, metadata} <- portable_value(result.metadata),
         value = %{
           "intent_id" => result.intent_id,
           "kind" => Atom.to_string(result.kind),
           "status" => Atom.to_string(result.status),
           "output" => output,
           "metadata" => metadata
         },
         :ok <- Value.validate(value),
         {:ok, bytes} <- CanonicalJSON.encode(value) do
      {:ok, Jido.Console.Digest.portable(bytes)}
    end
  end

  defp portable_value(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp portable_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp portable_value(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, items} ->
      case portable_value(item) do
        {:ok, portable} -> {:cont, {:ok, [portable | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp portable_value(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, items} ->
      with {:ok, key} <- portable_key(key),
           {:ok, item} <- portable_value(item) do
        {:cont, {:ok, Map.put(items, key, item)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp portable_value(_value), do: {:error, :nonportable_effect_value}

  defp portable_key(key) when is_binary(key), do: {:ok, key}
  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(_key), do: {:error, :nonportable_effect_map_key}

  defp barrier(opts, boundary) do
    if Keyword.get(opts, :crash_at) == boundary,
      do: {:error, {:injected_effect_crash, boundary}},
      else: :ok
  end

  defp read_opts(opts), do: Keyword.merge(opts, limit: @max_records, max_bytes: @max_bytes)
  defp scope_id(session_id, effect_id), do: "effect:#{session_id}:#{effect_id}"
  defp storage(opts), do: Keyword.get(opts, :storage, Storage)

  defp forbidden_values(opts) do
    values = Keyword.get(opts, :forbidden_values, [])

    case Keyword.get(opts, :credential_value) do
      value when is_binary(value) and value != "" -> [value | values]
      _other -> values
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp valid_id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,255}\z/, value)

  defp redacted_reason(_reason), do: :redacted
end
