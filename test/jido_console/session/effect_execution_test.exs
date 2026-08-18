defmodule Jido.Console.Session.EffectExecutionTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{EffectExecution, Generation, Manifest}
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jidoka.Effect.{Intent, Journal, Result}

  @digest "sha256:" <> String.duplicate("a", 64)
  @canary "EFFECT_CREDENTIAL_CANARY_DO_NOT_STORE"

  setup do
    token = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "jido-effect-execution-#{token}")

    names = [
      name: unique(:supervisor),
      lock: unique(:lock),
      maintenance: unique(:maintenance),
      quota: unique(:quota),
      admission: unique(:admission),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(names)
    Process.unlink(supervisor)
    storage = Keyword.take(names, [:writer, :quota, :admission])

    assert {:ok, _manifest} =
             Manifest.create(
               "session-main",
               manifest(),
               storage ++ [operation_id: "manifest-create-#{System.unique_integer([:positive])}"]
             )

    assert {:ok, fence} =
             Generation.claim(
               "session-main",
               storage ++
                 [
                   expected_generation: 0,
                   owner_instance_id: "owner-main",
                   operation_id: "generation-claim-#{System.unique_integer([:positive])}"
                 ]
             )

    assert {:ok, journal_agent} = Agent.start_link(fn -> {Journal.new!(), 0} end)
    assert {:ok, call_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      File.rm_rf(root)
    end)

    %{
      root: root,
      storage: storage,
      fence: fence,
      journal_agent: journal_agent,
      call_agent: call_agent
    }
  end

  test "commits the full reservation and Jidoka intent before dispatch", context do
    intent = operation_intent("effect-reserved", :idempotent)
    authority = authority(context.fence, intent, "attempt-1")

    dispatch = fn effect ->
      Agent.update(context.call_agent, &(&1 + 1))
      assert {:ok, inspection} = EffectExecution.inspect("session-main", effect.id, context.storage)
      [attempt] = inspection.attempts
      assert attempt.reservation["result_id"] == "result-effect-reserved"
      assert attempt.reservation["effect_kind"] == "operation"
      assert attempt.reservation["effective_arguments"]["name"] == "read_file"
      assert attempt.reservation["generation"] == 1
      assert attempt.reservation["required_permission"] == "tool:read_file"
      assert attempt.latest_status == "started"

      {journal, _revision} = Agent.get(context.journal_agent, & &1)
      assert Journal.intent_recorded?(journal, effect)
      {:ok, Result.ok(effect, %{"content" => "done"})}
    end

    assert {:ok, result} =
             EffectExecution.execute(intent, authority, execution_opts(context, dispatch))

    assert result.status == :completed
    assert result.dispatched
    assert Agent.get(context.call_agent, & &1) == 1
    assert {:ok, inspection} = EffectExecution.inspect("session-main", intent.id, context.storage)
    [attempt] = inspection.attempts
    assert Enum.map(attempt.states, & &1["status"]) == ["intent_recorded", "started", "completed"]
    assert attempt.terminal
  end

  test "reuses a completed Jidoka result without a second external call", context do
    intent = operation_intent("effect-reuse", :idempotent)
    authority = authority(context.fence, intent, "attempt-1")
    dispatch = counted_dispatch(context, %{"value" => 1})

    assert {:ok, %{status: :completed}} =
             EffectExecution.execute(intent, authority, execution_opts(context, dispatch))

    assert {:ok, %{status: :replayed, dispatched: false}} =
             EffectExecution.execute(
               intent,
               authority,
               execution_opts(context, fn _intent -> flunk("completed effect was dispatched") end)
             )

    assert Agent.get(context.call_agent, & &1) == 1
  end

  test "model calls use the same reservation and result truth", context do
    intent =
      Intent.new(:llm, %{"prompt" => %{"messages" => [%{"role" => "user", "content" => "hello"}]}},
        id: "effect-model",
        idempotency: :idempotent,
        idempotency_key: "key-effect-model"
      )

    assert {:ok, %{status: :completed, dispatched: true}} =
             EffectExecution.execute(
               intent,
               authority(context.fence, intent, "attempt-model"),
               execution_opts(context, counted_dispatch(context, %{"content" => "hello"}))
             )

    assert {:ok, inspection} = EffectExecution.inspect("session-main", intent.id, context.storage)
    [attempt] = inspection.attempts
    assert attempt.reservation["effect_kind"] == "llm"
    assert attempt.reservation["jidoka_intent_id"] == intent.id
    assert attempt.latest_status == "completed"
  end

  test "a terminal failed attempt does not dispatch again", context do
    intent = operation_intent("effect-terminal-failure", :idempotent)
    authority = authority(context.fence, intent, "attempt-1")

    failing_dispatch = fn _intent ->
      Agent.update(context.call_agent, &(&1 + 1))
      {:error, %RuntimeError{message: @canary}}
    end

    assert {:ok, %{status: :failed, reason: :redacted, dispatched: true}} =
             EffectExecution.execute(intent, authority, execution_opts(context, failing_dispatch))

    assert {:ok, %{status: :failed, dispatched: false}} =
             EffectExecution.execute(
               intent,
               authority,
               execution_opts(context, fn _intent -> flunk("terminal attempt was dispatched") end)
             )

    assert Agent.get(context.call_agent, & &1) == 1
    database = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    refute File.read!(database) =~ @canary
  end

  test "an incomplete unsafe effect becomes uncertain and is never repeated", context do
    intent = operation_intent("effect-unsafe", :unsafe_once)
    first = authority(context.fence, intent, "attempt-1")

    assert {:error, {:injected_effect_crash, :after_dispatch}} =
             EffectExecution.execute(
               intent,
               first,
               execution_opts(context, counted_dispatch(context, %{"charged" => true}), crash_at: :after_dispatch)
             )

    second = authority(context.fence, intent, "attempt-2", prior_attempt_id: "attempt-1")

    assert {:ok, %{status: :uncertain, action: :uncertain, dispatched: false}} =
             EffectExecution.execute(
               intent,
               second,
               execution_opts(context, fn _intent -> flunk("unsafe effect was repeated") end)
             )

    assert Agent.get(context.call_agent, & &1) == 1
    assert {:ok, inspection} = EffectExecution.inspect("session-main", intent.id, context.storage)
    assert Enum.map(inspection.attempts, & &1.latest_status) == ["started", "uncertain"]
    assert List.last(inspection.attempts).reservation["prior_attempt_id"] == "attempt-1"
  end

  test "safe replay uses a new linked attempt after an incomplete call", context do
    intent = operation_intent("effect-safe-replay", :idempotent)

    assert {:error, {:injected_effect_crash, :after_dispatch}} =
             EffectExecution.execute(
               intent,
               authority(context.fence, intent, "attempt-1"),
               execution_opts(context, counted_dispatch(context, %{"try" => 1}), crash_at: :after_dispatch)
             )

    assert {:ok, %{status: :uncertain, action: :new_attempt, dispatched: false}} =
             EffectExecution.execute(
               intent,
               authority(context.fence, intent, "attempt-1"),
               execution_opts(context, fn _intent -> flunk("the same attempt was repeated") end)
             )

    second = authority(context.fence, intent, "attempt-2", prior_attempt_id: "attempt-1")

    assert {:ok, %{status: :completed, dispatched: true}} =
             EffectExecution.execute(
               intent,
               second,
               execution_opts(context, counted_dispatch(context, %{"try" => 2}))
             )

    assert Agent.get(context.call_agent, & &1) == 2
    assert {:ok, inspection} = EffectExecution.inspect("session-main", intent.id, context.storage)
    assert Enum.map(inspection.attempts, & &1.latest_status) == ["uncertain", "completed"]
  end

  test "dedupe and reconcile effects stop for explicit reconciliation", context do
    for idempotency <- [:dedupe, :reconcile] do
      intent = operation_intent("effect-#{idempotency}", idempotency)

      assert {:error, {:injected_effect_crash, :after_dispatch}} =
               EffectExecution.execute(
                 intent,
                 authority(context.fence, intent, "attempt-1"),
                 execution_opts(context, counted_dispatch(context, %{"sent" => true}), crash_at: :after_dispatch)
               )

      assert {:ok, %{status: :uncertain, action: :reconcile, dispatched: false}} =
               EffectExecution.execute(
                 intent,
                 authority(context.fence, intent, "attempt-2", prior_attempt_id: "attempt-1"),
                 execution_opts(context, fn _intent -> flunk("effect was repeated") end)
               )
    end

    assert Agent.get(context.call_agent, & &1) == 2
  end

  test "stale generation, permission, and workspace cannot reach dispatch", context do
    intent = operation_intent("effect-fenced", :idempotent)
    dispatch = fn _intent -> flunk("stale authority reached dispatch") end

    stale_permission =
      authority(context.fence, intent, "permission-stale")
      |> put_in([:permission, :generation], 0)

    assert {:error, {:stale_effect_authority, :generation}} =
             EffectExecution.execute(intent, stale_permission, execution_opts(context, dispatch))

    drifted =
      authority(context.fence, intent, "workspace-drift")
      |> put_in([:current_manifest, "workspace_digest"], digest("b"))

    assert {:error, {:workspace_drift, _details}} =
             EffectExecution.execute(intent, drifted, execution_opts(context, dispatch))

    started = authority(context.fence, intent, "generation-started")

    assert {:error, {:injected_effect_crash, :after_started}} =
             EffectExecution.execute(
               intent,
               started,
               execution_opts(context, dispatch, crash_at: :after_started)
             )

    assert {:ok, newer} =
             Generation.claim(
               "session-main",
               context.storage ++
                 [
                   expected_generation: 1,
                   owner_instance_id: "owner-new",
                   operation_id: "generation-new"
                 ]
             )

    assert newer.generation == 2

    assert {:error, {:stale_generation, "session-main", 1, 2}} =
             EffectExecution.execute(intent, started, execution_opts(context, dispatch))

    assert {:error, {:stale_generation, "session-main", 1, 2}} =
             EffectExecution.execute(
               intent,
               authority(context.fence, intent, "generation-stale"),
               execution_opts(context, dispatch)
             )
  end

  test "sensitive arguments and results never enter either durable truth", context do
    sensitive_intent =
      Intent.new(:operation, %{"name" => "send", "arguments" => %{"api_key" => @canary}},
        id: "effect-sensitive-argument",
        idempotency: :idempotent,
        idempotency_key: "key-sensitive-argument"
      )

    assert {:error, {:sensitive_value_rejected, _redacted}} =
             EffectExecution.execute(
               sensitive_intent,
               authority(context.fence, sensitive_intent, "attempt-argument"),
               execution_opts(context, fn _intent -> flunk("sensitive argument dispatched") end,
                 forbidden_values: [@canary]
               )
             )

    result_intent = operation_intent("effect-sensitive-result", :unsafe_once)

    assert {:error, :sensitive_result_blocked} =
             EffectExecution.execute(
               result_intent,
               authority(context.fence, result_intent, "attempt-result"),
               execution_opts(context, counted_dispatch(context, @canary), credential_value: @canary)
             )

    {journal, _revision} = Agent.get(context.journal_agent, & &1)
    refute Journal.result_for(journal, result_intent)

    assert {:ok, inspection} = EffectExecution.inspect("session-main", result_intent.id, context.storage)
    [attempt] = inspection.attempts
    assert attempt.latest_status == "started"

    database = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    refute File.read!(database) =~ @canary
  end

  test "deterministic barriers cover each durability boundary", context do
    boundaries = [
      :after_reservation,
      :after_intent,
      :after_started,
      :after_dispatch,
      :after_jidoka_result,
      :after_console_result
    ]

    for boundary <- boundaries do
      intent = operation_intent("effect-crash-#{boundary}", :idempotent)
      first = authority(context.fence, intent, "attempt-1")

      assert {:error, {:injected_effect_crash, ^boundary}} =
               EffectExecution.execute(
                 intent,
                 first,
                 execution_opts(context, counted_dispatch(context, %{"boundary" => Atom.to_string(boundary)}),
                   crash_at: boundary
                 )
               )

      retry_authority =
        if boundary in [:after_started, :after_dispatch],
          do: authority(context.fence, intent, "attempt-2", prior_attempt_id: "attempt-1"),
          else: first

      assert {:ok, retry} =
               EffectExecution.execute(
                 intent,
                 retry_authority,
                 execution_opts(context, counted_dispatch(context, %{"retry" => true}))
               )

      assert retry.status in [:completed, :replayed]
    end

    # No call occurs before intent/start. A safe unknown call repeats once. A
    # committed Jidoka result and a committed Console result never repeat.
    assert Agent.get(context.call_agent, & &1) == 7
  end

  test "explicit reconciliation records decisions and requires Jidoka truth for completion", context do
    intent = operation_intent("effect-reconcile-decision", :unsafe_once)
    authority = authority(context.fence, intent, "attempt-1")

    assert {:error, {:injected_effect_crash, :after_dispatch}} =
             EffectExecution.execute(
               intent,
               authority,
               execution_opts(context, counted_dispatch(context, %{"unknown" => true}), crash_at: :after_dispatch)
             )

    assert {:error, {:jidoka_result_required_for_reconciliation, "result-effect-reconcile-decision"}} =
             EffectExecution.reconcile(
               intent,
               authority,
               %{decision_id: "decision-complete", outcome: :completed},
               execution_opts(context, fn _intent -> flunk("reconciliation dispatched") end)
             )

    assert {:ok, %{status: :abandoned}} =
             EffectExecution.reconcile(
               intent,
               authority,
               %{decision_id: "decision-abandon", outcome: :abandoned},
               execution_opts(context, fn _intent -> flunk("reconciliation dispatched") end)
             )
  end

  test "exports the closed replay table and rejects unsupported identities" do
    assert {:ok, %{replay_rule: "replay", incomplete: :dispatch}} =
             EffectExecution.replay_policy(:pure)

    assert {:ok, %{replay_rule: "dedupe", incomplete: :reconcile}} =
             EffectExecution.replay_policy(:dedupe)

    assert {:ok, %{replay_rule: "reconcile", incomplete: :reconcile}} =
             EffectExecution.replay_policy(:reconcile)

    assert {:ok, %{replay_rule: "never", incomplete: :uncertain}} =
             EffectExecution.replay_policy(:unsafe_once)

    assert {:error, {:unsupported_effect_idempotency, :unknown}} =
             EffectExecution.replay_policy(:unknown)

    assert {:error, :invalid_effect_execution} = EffectExecution.execute(:invalid, %{})
    assert {:error, :invalid_effect_inspection} = EffectExecution.inspect(:invalid, :invalid)
    assert {:error, :invalid_effect_reconciliation} = EffectExecution.reconcile(:invalid, %{}, %{})
  end

  test "returns typed errors for invalid callbacks, identities, and portable values", context do
    base = operation_intent("effect-error-base", :idempotent)
    base_authority = authority(context.fence, base, "attempt-base")
    opts = execution_opts(context, counted_dispatch(context, %{"ok" => true}))

    assert {:error, :cross_session_effect_fence} =
             EffectExecution.execute(base, %{base_authority | session_id: "other-session"}, opts)

    assert {:error, {:invalid_effect_identity, :attempt_id}} =
             EffectExecution.execute(base, %{base_authority | attempt_id: "bad attempt"}, opts)

    assert {:error, :effect_permission_required} =
             EffectExecution.execute(base, %{base_authority | permission: nil}, opts)

    assert {:error, {:stale_effect_authority, :approval_id}} =
             EffectExecution.execute(base, put_in(base_authority, [:permission, :id], ""), opts)

    no_permission = operation_intent("effect-no-permission", :pure)

    no_permission_authority =
      authority(context.fence, no_permission, "attempt-none")
      |> Map.put(:required_permission, "none")
      |> Map.put(:permission, nil)
      |> Map.put(:operation_id, "custom-effect-operation")

    assert {:ok, %{status: :completed}} =
             EffectExecution.execute(
               no_permission,
               no_permission_authority,
               execution_opts(context, counted_dispatch(context, %{"ok" => true}))
             )

    conflict = operation_intent("effect-attempt-conflict", :idempotent)
    conflict_authority = authority(context.fence, conflict, "attempt-conflict")

    assert {:error, {:injected_effect_crash, :after_reservation}} =
             EffectExecution.execute(
               conflict,
               conflict_authority,
               execution_opts(context, counted_dispatch(context, %{}), crash_at: :after_reservation)
             )

    assert {:error, {:effect_attempt_conflict, "attempt-conflict"}} =
             EffectExecution.execute(
               conflict,
               %{conflict_authority | result_id: "different-result"},
               execution_opts(context, counted_dispatch(context, %{}))
             )

    missing = operation_intent("effect-missing-reservation", :unsafe_once)

    assert {:error, {:effect_reservation_not_found, "attempt-missing"}} =
             EffectExecution.reconcile(
               missing,
               authority(context.fence, missing, "attempt-missing"),
               %{decision_id: "decision-missing", outcome: :abandoned},
               execution_opts(context, counted_dispatch(context, %{}))
             )

    cancelled = operation_intent("effect-cancelled", :idempotent)

    assert {:ok, %{status: :cancelled, reason: :redacted}} =
             EffectExecution.execute(
               cancelled,
               authority(context.fence, cancelled, "attempt-cancelled"),
               execution_opts(context, fn _intent -> {:cancelled, @canary} end)
             )

    mismatch = operation_intent("effect-result-mismatch", :idempotent)
    other = operation_intent("effect-other", :idempotent)

    assert {:error, :jidoka_effect_result_identity_mismatch} =
             EffectExecution.execute(
               mismatch,
               authority(context.fence, mismatch, "attempt-mismatch"),
               execution_opts(context, fn _intent -> {:ok, Result.ok(other, %{})} end)
             )

    invalid_dispatch = operation_intent("effect-invalid-dispatch", :idempotent)

    assert {:error, :invalid_effect_dispatch_result} =
             EffectExecution.execute(
               invalid_dispatch,
               authority(context.fence, invalid_dispatch, "attempt-invalid-dispatch"),
               execution_opts(context, fn _intent -> :invalid end)
             )

    missing_dispatch = operation_intent("effect-missing-dispatch", :idempotent)
    missing_dispatch_opts = Keyword.delete(execution_opts(context, fn _intent -> :ok end), :dispatch)

    assert {:error, :effect_dispatch_required} =
             EffectExecution.execute(
               missing_dispatch,
               authority(context.fence, missing_dispatch, "attempt-missing-dispatch"),
               missing_dispatch_opts
             )

    for {id, persist, expected} <- [
          {"invalid", fn _journal, _phase -> :invalid end, :invalid_jidoka_journal_commit},
          {"error", fn _journal, _phase -> {:error, :journal_down} end, :journal_down}
        ] do
      intent = operation_intent("effect-journal-#{id}", :idempotent)
      journal_opts = Keyword.put(execution_opts(context, fn _intent -> :ok end), :persist_journal, persist)

      assert {:error, ^expected} =
               EffectExecution.execute(
                 intent,
                 authority(context.fence, intent, "attempt-journal-#{id}"),
                 journal_opts
               )
    end

    no_commit = operation_intent("effect-no-journal-commit", :idempotent)
    no_commit_opts = Keyword.delete(execution_opts(context, fn _intent -> :ok end), :persist_journal)

    assert {:error, :jidoka_journal_commit_required} =
             EffectExecution.execute(
               no_commit,
               authority(context.fence, no_commit, "attempt-no-commit"),
               no_commit_opts
             )

    for {id, payload, expected} <- [
          {"pid", %{"value" => self()}, :nonportable_effect_value},
          {"list", %{"value" => [self()]}, :nonportable_effect_value},
          {"key", %{1 => "value"}, :nonportable_effect_map_key}
        ] do
      intent = Intent.new(:llm, payload, id: "effect-portable-#{id}", idempotency_key: "key-portable-#{id}")

      assert {:error, ^expected} =
               EffectExecution.execute(
                 intent,
                 authority(context.fence, intent, "attempt-portable-#{id}"),
                 execution_opts(context, counted_dispatch(context, %{}))
               )
    end

    atom_value = Intent.new(:llm, %{"mode" => :fast}, id: "effect-atom", idempotency_key: "key-atom")

    assert {:ok, %{status: :completed}} =
             EffectExecution.execute(
               atom_value,
               authority(context.fence, atom_value, "attempt-atom"),
               execution_opts(context, counted_dispatch(context, %{}))
             )
  end

  defp execution_opts(context, dispatch, extra \\ []) do
    {journal, revision} = Agent.get(context.journal_agent, & &1)

    persist = fn next_journal, _phase ->
      Agent.get_and_update(context.journal_agent, fn {_current, current_revision} ->
        next_revision = current_revision + 1
        {{:ok, next_revision}, {next_journal, next_revision}}
      end)
    end

    context.storage ++
      [
        journal: journal,
        jidoka_revision: revision,
        persist_journal: persist,
        dispatch: dispatch
      ] ++ extra
  end

  defp counted_dispatch(context, output) do
    fn intent ->
      Agent.update(context.call_agent, &(&1 + 1))
      {:ok, Result.ok(intent, output)}
    end
  end

  defp authority(fence, intent, attempt_id, opts \\ []) do
    %{
      session_id: "session-main",
      request_id: "request-main",
      attempt_id: attempt_id,
      prior_attempt_id: Keyword.get(opts, :prior_attempt_id),
      result_id: "result-#{intent.id}",
      required_permission: "tool:read_file",
      current_manifest: current_manifest(),
      fence: fence,
      permission: %{
        id: "approval-#{attempt_id}",
        decision: :approved,
        session_id: "session-main",
        generation: fence.generation,
        owner_instance_id: fence.owner_instance_id,
        scope: "tool:read_file",
        effect_id: intent.id
      }
    }
  end

  defp operation_intent(id, idempotency) do
    Intent.new(:operation, %{"name" => "read_file", "arguments" => %{"path" => "README.md"}},
      id: id,
      idempotency: idempotency,
      idempotency_key: "key-#{id}"
    )
  end

  defp manifest do
    %{
      "request_id" => "request-main",
      "invocation_id" => "invocation-main",
      "provider_id" => "provider-main",
      "model_id" => "model-main",
      "variant_id" => "variant-main",
      "settings_digest" => @digest,
      "agent_spec_digest" => @digest,
      "prompt_digest" => @digest,
      "tool_schema_digest" => @digest,
      "skill_schema_digest" => @digest,
      "extension_descriptor_digest" => @digest,
      "protocol_digest" => @digest,
      "coding_profile_id" => "coding-main",
      "workspace_id" => "workspace-main",
      "workspace_digest" => @digest,
      "credential_profile_id" => nil,
      "credential_profile_version" => nil,
      "credential_reference_id" => nil,
      "credential_source_identity" => nil,
      "execution_environment_id" => nil
    }
  end

  defp current_manifest do
    Map.take(manifest(), [
      "provider_id",
      "model_id",
      "variant_id",
      "settings_digest",
      "agent_spec_digest",
      "prompt_digest",
      "tool_schema_digest",
      "skill_schema_digest",
      "extension_descriptor_digest",
      "protocol_digest",
      "coding_profile_id",
      "execution_environment_id",
      "workspace_id",
      "workspace_digest"
    ])
  end

  defp digest(character), do: "sha256:" <> String.duplicate(character, 64)
  defp unique(label), do: String.to_atom("effect-#{label}-#{System.unique_integer([:positive])}")
end
