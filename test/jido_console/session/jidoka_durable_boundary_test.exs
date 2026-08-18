defmodule Jido.Console.Session.JidokaDurableBoundaryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Jidoka, as: SessionJidoka
  alias Jidoka.Effect
  alias Jidoka.Session.Data
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Store
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  test "normal and explicit imported mappings validate every transition" do
    session = session("console-session")
    {:ok, normal} = SessionJidoka.session_mapping("console-session")
    request = request("request-normal")

    assert :ok = SessionJidoka.validate_session(normal, session)

    assert {:ok, %Data{revision: 1, lease: %Lease{lease_id: "lease-normal"}}} =
             SessionJidoka.claim_transition(normal, session, request,
               clock: fn -> 100 end,
               owner_id: "worker-normal",
               id_generator: id_generator("lease-normal")
             )

    assert {:error, {:jidoka_session_mapping_mismatch, "console-session", "other-session"}} =
             normal
             |> Map.put("jidoka_session_id", "other-session")
             |> SessionJidoka.claim_transition(session, request)

    assert {:error, {:jidoka_session_mapping_mismatch, "console-session", "jidoka-session"}} =
             SessionJidoka.session_mapping("console-session", jidoka_session_id: "jidoka-session")

    assert {:ok, imported} =
             SessionJidoka.session_mapping("console-session",
               jidoka_session_id: "jidoka-session",
               kind: :imported
             )

    assert :ok = SessionJidoka.validate_session(imported, session("jidoka-session"))
  end

  test "Console receipt metadata is canonical, namespaced, JSON-only, and bounded" do
    receipt = receipt()

    assert SessionJidoka.request_metadata_limits() == %{max_keys: 16, max_bytes: 4_096}

    assert {:ok, %{"jido_console" => %{"receipt" => ^receipt}} = metadata} =
             SessionJidoka.request_metadata(receipt)

    assert map_size(metadata) == 1
    assert {:ok, encoded} = Jido.Console.Session.Durable.CanonicalJSON.encode(metadata)
    assert byte_size(encoded) <= 4_096

    assert {:error, {:sensitive_value_rejected, _, _}} =
             receipt
             |> put_in(["payload", "token"], "CANARY_DO_NOT_STORE")
             |> SessionJidoka.request_metadata()

    assert {:error, _reason} =
             receipt
             |> Map.put("type", "client_output")
             |> SessionJidoka.request_metadata()

    assert {:error, {:forbidden_runtime_value, :pid}} =
             receipt
             |> put_in(["payload", "extra"], self())
             |> SessionJidoka.request_metadata()

    too_many =
      Enum.reduce(1..10, receipt, fn index, value ->
        put_in(value, ["payload", "extra_#{index}"], index)
      end)

    assert {:error, {:oversized_console_receipt_metadata, :keys, 16}} =
             SessionJidoka.request_metadata(too_many)

    assert {:error, {:oversized_console_receipt_metadata, :bytes, size, 4_096}} =
             receipt
             |> put_in(["payload", "note"], String.duplicate("x", 3_900))
             |> SessionJidoka.request_metadata()

    assert size > 4_096
  end

  test "checkpoint, recovery, effect replay, and terminal commit use public data" do
    source = session("durable-session")
    {:ok, mapping} = SessionJidoka.session_mapping(source.session_id)
    request = request("request-durable")

    assert {:ok, %Data{revision: 1} = claimed} =
             SessionJidoka.claim_transition(mapping, source, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               owner_id: "worker-one",
               id_generator: id_generator("lease-one")
             )

    snapshot = snapshot(claimed, "snapshot-durable", effect: true)

    assert {:ok, %Data{revision: 2} = checkpointed} =
             SessionJidoka.checkpoint_transition(mapping, claimed, "lease-one", snapshot,
               clock: fn -> 110 end,
               lease_ttl_ms: 50
             )

    console_fence = %{
      session_id: "durable-session",
      generation: 7,
      owner_instance_id: "console-owner",
      operation_id: "watermark-operation",
      state: :active
    }

    assert {:ok,
            %{
              console_session_id: "durable-session",
              jidoka_session_id: "durable-session",
              jidoka_revision: 2,
              jidoka_request_id: "request-durable",
              jidoka_lease_id: "lease-one",
              jidoka_snapshot_id: "snapshot-durable",
              console_generation: 7,
              console_owner_instance_id: "console-owner",
              console_operation_id: "watermark-operation"
            }} =
             SessionJidoka.checkpoint_identity(mapping, checkpointed, snapshot, console_fence: console_fence)

    assert {:ok,
            %{
              jidoka_revision: 2,
              jidoka_request_id: "request-durable",
              jidoka_lease_id: "lease-one",
              console_generation: 7,
              target: %{kind: :resume, snapshot_id: "snapshot-durable"}
            }} =
             SessionJidoka.recovery_identity(mapping, checkpointed, console_fence: console_fence)

    assert {:ok, replay} = SessionJidoka.replay(mapping, checkpointed)
    assert [%{snapshot_id: "snapshot-durable"}] = replay.snapshots
    assert [%{id: "effect-durable", idempotency: :unsafe_once}] = replay.journal.intents

    assert {:ok, %Data{revision: 3, lease: %Lease{lease_id: "lease-two"}} = recovered} =
             SessionJidoka.recover_transition(mapping, checkpointed,
               clock: fn -> 160 end,
               lease_ttl_ms: 50,
               owner_id: "worker-two",
               id_generator: id_generator("lease-two")
             )

    assert {:ok, %Data{revision: 4, lease: nil, status: :error}} =
             SessionJidoka.commit_transition(
               mapping,
               recovered,
               "lease-two",
               Data.put_error(recovered, :recovered),
               clock: fn -> 161 end
             )
  end

  test "resume transition and public fork preserve explicit identities" do
    source = session("source-session")
    {:ok, source_mapping} = SessionJidoka.session_mapping(source.session_id)
    request = request("request-fork")

    {:ok, claimed} =
      SessionJidoka.claim_transition(source_mapping, source, request,
        clock: fn -> 200 end,
        lease_ttl_ms: 50,
        id_generator: id_generator("lease-source")
      )

    source_snapshot = snapshot(claimed, "snapshot-source")
    completed = Data.put_snapshot(claimed, source_snapshot)

    assert {:ok, %Data{status: :hibernated, lease: nil} = hibernated} =
             SessionJidoka.commit_transition(
               source_mapping,
               claimed,
               "lease-source",
               completed,
               clock: fn -> 201 end
             )

    assert {:ok, %Data{lease: %Lease{lease_id: "lease-resume"}}} =
             SessionJidoka.resume_transition(source_mapping, hibernated,
               clock: fn -> 202 end,
               id_generator: id_generator("lease-resume")
             )

    {:ok, store_pid} = InMemory.start_link()
    on_exit(fn -> if Process.alive?(store_pid), do: Agent.stop(store_pid) end)
    store = {InMemory, pid: store_pid}
    assert {:ok, ^hibernated} = Store.put_session(store, hibernated)

    {:ok, child_mapping} =
      SessionJidoka.session_mapping("console-child",
        jidoka_session_id: "jidoka-child",
        kind: :forked
      )

    assert {:ok, %Data{session_id: "jidoka-child"} = child} =
             SessionJidoka.fork(source_mapping, child_mapping,
               store: store,
               clock: fn -> 203 end,
               fork_snapshot_id: "snapshot-child"
             )

    assert {:ok,
            %{
              console_session_id: "console-child",
              jidoka_session_id: "jidoka-child",
              root_session_id: "source-session",
              parent_session_id: "source-session",
              source_snapshot_id: "snapshot-source",
              depth: 1,
              console_generation: 1,
              console_owner_instance_id: "child-owner"
            }} =
             SessionJidoka.fork_identity(child_mapping, child,
               console_fence: %{
                 session_id: "console-child",
                 generation: 1,
                 owner_instance_id: "child-owner",
                 operation_id: "child-fork",
                 state: :active
               }
             )
  end

  test "rejects invalid mappings, unlinked data, and generation fences" do
    source = session("boundary-session")
    {:ok, mapping} = SessionJidoka.session_mapping(source.session_id)

    assert {:error, :invalid_jidoka_session_mapping} =
             SessionJidoka.session_mapping(source.session_id, kind: :unknown)

    assert {:error, :invalid_jidoka_session_mapping} = SessionJidoka.session_mapping("")

    oversized = String.duplicate("x", 257)

    assert {:error, {:oversized_jidoka_session_identity, 257, 256}} =
             SessionJidoka.session_mapping(oversized)

    assert {:error, :invalid_jidoka_session_mapping} = SessionJidoka.validate_session(%{}, source)
    assert {:error, :invalid_jidoka_session_mapping} = SessionJidoka.validate_session(mapping, :invalid)
    assert {:error, :invalid_console_receipt_metadata} = SessionJidoka.request_metadata(:invalid)

    assert {:ok, ^source} = SessionJidoka.put_transition(mapping, nil, source)

    assert {:error, :invalid_jidoka_session_mapping} =
             SessionJidoka.put_transition(mapping, :invalid, source)

    assert {:error, {:jidoka_session_not_recoverable, "boundary-session"}} =
             SessionJidoka.recovery_identity(mapping, source)

    assert {:error, {:jidoka_session_has_no_fork_lineage, "boundary-session"}} =
             SessionJidoka.fork_identity(mapping, source)

    assert {:error, :forked_jidoka_session_mapping_required} =
             SessionJidoka.fork(mapping, mapping)

    assert {:error, :invalid_jidoka_session_mapping} = SessionJidoka.fork(%{}, mapping)

    request = request("boundary-request")

    {:ok, claimed} =
      SessionJidoka.claim_transition(mapping, source, request,
        clock: fn -> 1 end,
        id_generator: id_generator("boundary-lease")
      )

    assert {:ok, %{target: %{kind: :restart, request_id: "boundary-request"}}} =
             SessionJidoka.recovery_identity(mapping, claimed)

    assert {:ok, renewed} =
             SessionJidoka.renew_transition(mapping, claimed, "boundary-lease", clock: fn -> 2 end)

    checkpoint = snapshot(renewed, "boundary-snapshot")

    {:ok, committed} =
      SessionJidoka.checkpoint_transition(mapping, renewed, "boundary-lease", checkpoint, clock: fn -> 3 end)

    assert {:ok, identity} = SessionJidoka.checkpoint_identity(mapping, committed, checkpoint)
    refute Map.has_key?(identity, :console_generation)

    assert {:error, :invalid_generation} =
             SessionJidoka.checkpoint_identity(mapping, committed, checkpoint, console_fence: %{})

    cross_fence = %{
      session_id: "other-session",
      generation: 1,
      owner_instance_id: "other-owner",
      operation_id: "other-operation",
      state: :active
    }

    assert {:error, :cross_session_generation_fence} =
             SessionJidoka.checkpoint_identity(mapping, committed, checkpoint, console_fence: cross_fence)
  end

  defp session(session_id) do
    {:ok, session} = Data.start(Jido.Console.DefaultAgent.spec(), session_id: session_id)
    session
  end

  defp request(request_id) do
    Turn.Request.new!(input: "Continue", request_id: request_id)
  end

  defp snapshot(%Data{} = session, snapshot_id, opts \\ []) do
    request = List.last(session.requests)

    %Turn.State{} =
      state =
      Turn.State.new!(
        spec: session.spec,
        plan: Turn.Plan.new!(session.spec),
        request: request,
        agent_state: request.agent_state
      )

    state =
      if Keyword.get(opts, :effect, false) do
        intent =
          Effect.Intent.new(:operation, %{name: "read", arguments: %{}},
            id: "effect-durable",
            idempotency_key: "effect-key",
            idempotency: :unsafe_once
          )

        %Turn.State{state | journal: Effect.Journal.put_intent(state.journal, intent)}
      else
        state
      end

    Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt(), snapshot_id: snapshot_id)
  end

  defp receipt do
    %{
      "protocol" => "jido.session",
      "version" => "1",
      "family" => "receipt",
      "type" => "input",
      "id" => "receipt-1",
      "session_id" => "console-session",
      "payload" => %{
        "operation_id" => "operation-1",
        "idempotency_key" => "input-1",
        "payload_digest" => "sha256:payload",
        "sequence" => 1,
        "durability" => "durable",
        "commit_boundary" => "sqlite_full_commit",
        "status" => "committed"
      }
    }
  end

  defp id_generator(id), do: fn "lease" -> id end
end
