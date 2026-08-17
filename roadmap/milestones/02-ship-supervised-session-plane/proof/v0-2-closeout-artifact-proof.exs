defmodule ExUnit.Callbacks do
  @moduledoc false

  def on_exit(callback) when is_function(callback, 0) do
    callbacks = Process.get(:m2e36_on_exit, [])
    Process.put(:m2e36_on_exit, [callback | callbacks])
    :ok
  end

  def run_callbacks do
    :m2e36_on_exit
    |> Process.get([])
    |> Enum.each(& &1.())

    Process.delete(:m2e36_on_exit)
    :ok
  end
end

defmodule Jido.Console.M2E36ArtifactProof do
  @moduledoc false

  alias Jido.Console.Session.{Cancellation, Delivery, Drain, Event, Identity, Recovery, Reducer, Server, State}
  alias Jido.Console.Session.Client.Boundary

  @session_id "m2e36-session"
  @client_id "m2e36-client"
  @attachment_id "m2e36-attachment"
  @identity %{
    session_id: @session_id,
    client_id: @client_id,
    attachment_id: @attachment_id
  }

  def run do
    Process.flag(:trap_exit, true)

    install_root = System.fetch_env!("JIDO_M2E36_INSTALL_ROOT") |> Path.expand()
    source_root = System.fetch_env!("JIDO_M2E36_SOURCE_ROOT") |> Path.expand()
    output_path = System.fetch_env!("JIDO_M2E36_PROOF_OUT") |> Path.expand()

    {:ok, _applications} = Application.ensure_all_started(:jido_console)

    code_paths = artifact_code_paths(install_root)
    receiver_bounds = stopped_receiver_bounds()
    recovery = recovery_and_incremental_output()
    lifecycle = lifecycle_and_cleanup()

    {parity, raw_path} =
      File.cd!(source_root, fn ->
        Code.require_file("test/support/current_client_parity.ex")
        Code.require_file("test/support/client_parity_boundary.ex")

        parity = current_client_parity()
        raw_path = raw_path_guard()
        ExUnit.Callbacks.run_callbacks()
        {parity, raw_path}
      end)

    report = %{
      "schema" => "jido.m2e36-artifact-proof",
      "schema_version" => 1,
      "status" => "pass",
      "artifact_runtime" => %{
        "install_root" => install_root,
        "private_runtime" => Path.join(install_root, "libexec/bin/jido"),
        "code_paths" => code_paths
      },
      "receiver_bounds" => receiver_bounds,
      "recovery_and_incremental_output" => recovery,
      "lifecycle_and_cleanup" => lifecycle,
      "current_client_parity" => parity,
      "raw_path_guard" => raw_path,
      "known_limit" => Recovery.limitation()
    }

    File.write!(output_path, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts(Jason.encode!(report, pretty: true))
  end

  defp artifact_code_paths(install_root) do
    modules = [
      Boundary,
      Cancellation,
      Delivery,
      Drain,
      Jido.Console.Session.Client,
      Jido.Console.Session.Client.Automation,
      Jido.Console.Session.Client.JSON,
      Jido.Console.Session.Client.Text,
      Jido.Console.Session.Client.TUI,
      Recovery,
      Server
    ]

    Map.new(modules, fn module ->
      path = module |> :code.which() |> List.to_string() |> Path.expand()
      check!(String.starts_with?(path, install_root <> "/"), {:module_outside_artifact, module, path})
      {inspect(module), path}
    end)
  end

  defp stopped_receiver_bounds do
    maximums = Delivery.maximums()
    attached = start_stopped_attached_receiver()

    stopped =
      Enum.reduce(1..10_000, delivery(), fn sequence, state ->
        case Delivery.offer(state, event(sequence)) do
          {:ok, next, _advisory?} ->
            next

          {:duplicate, next} ->
            next

          {:gap, next, _gap, _advisory?} ->
            next
        end
      end)

    inflight =
      Enum.reduce(1..maximums.batch_count, delivery(), fn sequence, state ->
        {:ok, next, _advisory?} = Delivery.offer(state, event(sequence))
        next
      end)

    {:ok, inflight, batch} = Delivery.pull(inflight, @identity)
    Process.sleep(maximums.ack_timeout_ms + 100)

    {:message_queue_len, mailbox_count} = Process.info(attached.receiver, :message_queue_len)
    {:messages, copied_messages} = Process.info(attached.receiver, :messages)
    copied_bytes = Enum.sum(Enum.map(copied_messages, &:erlang.external_size/1))
    stopped_measurements = Delivery.measurements(stopped)
    inflight_measurements = Delivery.measurements(inflight)

    {:ok, attached_measurements} =
      Server.delivery_measurements(attached.server, attached.client.id, attached.attachment.id)

    check!(mailbox_count <= maximums.advisory_count, {:mailbox_count, mailbox_count})
    check!(length(copied_messages) <= maximums.advisory_count, {:copied_count, copied_messages})
    check!(copied_bytes <= maximums.advisory_bytes, {:copied_bytes, copied_bytes})
    check!(attached_measurements.status == :gapped, {:attached_status, attached_measurements})
    check!(attached_measurements.queue_count == 0, {:attached_queue, attached_measurements})
    check!(attached_measurements.queued_bytes == 0, {:attached_bytes, attached_measurements})
    check!(stopped_measurements.status == :gapped, {:stopped_status, stopped_measurements})
    check!(stopped_measurements.queue_count == 0, {:stopped_queue, stopped_measurements})
    check!(stopped_measurements.queued_bytes == 0, {:stopped_bytes, stopped_measurements})
    check!(inflight.inflight.count <= maximums.batch_count, {:inflight_count, inflight.inflight})
    check!(inflight.inflight.bytes <= maximums.batch_bytes, {:inflight_bytes, inflight.inflight})
    check!(inflight.inflight.bytes <= maximums.copied_bytes, {:copied_batch_bytes, inflight.inflight})

    {:gap, timed_out, gap, _advisory?} =
      Delivery.timeout(inflight, @attachment_id, inflight.inflight.timer_token, maximums.batch_count)

    check!(gap["payload"]["reason"] == "acknowledgement_timeout", {:timeout_gap, gap})
    check!(Delivery.measurements(timed_out).inflight_bytes == 0, {:timeout_inflight, timed_out})
    send(attached.receiver, :release)
    :ok = Server.stop(attached.server)
    :ok = Supervisor.stop(attached.supervisor)

    %{
      "updates_offered" => 10_000,
      "attached_owner_operations" => attached.operations,
      "attached_owner_sequence" => attached.owner_sequence,
      "held_ms" => maximums.ack_timeout_ms + 100,
      "mailbox_count" => mailbox_count,
      "copied_message_count" => length(copied_messages),
      "copied_message_bytes" => copied_bytes,
      "attached_delivery" => stringify_measurements(attached_measurements),
      "stopped_delivery" => stringify_measurements(stopped_measurements),
      "inflight_batch" => %{
        "count" => inflight.inflight.count,
        "bytes" => inflight.inflight.bytes,
        "first_sequence" => batch["payload"]["first_sequence"],
        "through_sequence" => batch["payload"]["through_sequence"],
        "measurements" => stringify_measurements(inflight_measurements)
      },
      "limits" => stringify_map(maximums),
      "timeout_reason" => gap["payload"]["reason"]
    }
  end

  defp start_stopped_attached_receiver do
    suffix = System.unique_integer([:positive, :monotonic])

    names = [
      name: :"m2e36-bound-sup-#{suffix}",
      registry: :"m2e36-bound-reg-#{suffix}",
      sessions: :"m2e36-bound-sessions-#{suffix}"
    ]

    {:ok, supervisor} = Jido.Console.Session.Supervisor.start_link(names)
    session = Identity.new!(:session)
    {:ok, server} = Server.ensure_started(session.id, registry: names[:registry], supervisor: names[:sessions])
    client = Identity.new!(:client, session_id: session.id)
    proof = self()

    receiver =
      spawn(fn ->
        result = Server.attach(server, client)
        send(proof, {:m2e36_attached, self(), result})

        receive do
          :release -> :ok
        end
      end)

    attachment =
      receive do
        {:m2e36_attached, ^receiver, {:ok, %{attachment: attachment}}} -> attachment
      after
        1_000 -> raise "stopped receiver did not attach"
      end

    operations = 100

    Enum.each(1..operations, fn operation ->
      spec = [
        start: fn _owner -> {:ok, %{request_id: "m2e36-bound-#{operation}"}} end,
        await: fn _request -> :done end
      ]

      {:ok, request} = Server.start_operation(server, client.id, spec)
      :done = Server.await_request(server, request, 1_000)
    end)

    %{
      supervisor: supervisor,
      server: server,
      client: client,
      attachment: attachment,
      receiver: receiver,
      operations: operations,
      owner_sequence: Server.state(server).sequence
    }
  end

  defp recovery_and_incremental_output do
    first = event(1)
    second = event(2)
    third = event(3)
    fourth = event(4)

    {:ok, owner_at_gap} = Reducer.apply_event(State.new(@session_id), first)
    gap_delivery = delivery()
    {:ok, gap_delivery, _advisory?} = Delivery.offer(gap_delivery, first)
    {:ok, gap_delivery, _batch} = Delivery.pull(gap_delivery, @identity)

    {:gap, gap_delivery, gap, _advisory?} =
      Delivery.timeout(gap_delivery, @attachment_id, gap_delivery.inflight.timer_token, 1)

    {:ok, recovering, snapshot} =
      Recovery.begin(owner_at_gap, gap_delivery, @identity, gap["payload"]["gap_id"])

    {:ok, owner} = Reducer.apply_event(owner_at_gap, second)
    {:ok, owner} = Reducer.apply_event(owner, third)
    {:ok, recovering, false} = Delivery.offer(recovering, second)
    {:ok, recovering, false} = Delivery.offer(recovering, third)

    {:ok, recovering, suffix} =
      Recovery.replay(owner, recovering, @identity, snapshot["payload"]["recovery_token"])

    {:ok, restored} = Recovery.restore_snapshot(snapshot)
    {:ok, restored} = Recovery.apply_suffix(restored, suffix, @identity)
    check!(restored == owner, {:recovery_owner_mismatch, restored, owner})

    {:ok, open, receipt, false} =
      Recovery.complete(recovering, @identity, suffix["payload"]["completion_token"])

    {:ok, open, _advisory?} = Delivery.offer(open, fourth)
    {:ok, _open, post_recovery_batch} = Delivery.pull(open, @identity)

    ordinary = delivery()
    {:ok, ordinary, _advisory?} = Delivery.offer(ordinary, first)
    {:ok, ordinary, _advisory?} = Delivery.offer(ordinary, second)
    {:ok, ordinary, first_batch} = Delivery.pull(ordinary, @identity)

    {:ok, ordinary, _receipt, _advisory?} =
      Delivery.ack(ordinary, @identity, first_batch["payload"]["acknowledgement_token"])

    {:ok, ordinary, _advisory?} = Delivery.offer(ordinary, third)
    {:ok, _ordinary, next_batch} = Delivery.pull(ordinary, @identity)
    ordinary_types = [first_batch["type"], next_batch["type"]]

    check!(ordinary_types == ["output_batch", "output_batch"], {:ordinary_types, ordinary_types})
    check!(sequences(first_batch) == [1, 2], {:first_incremental_batch, first_batch})
    check!(sequences(next_batch) == [3], {:next_incremental_batch, next_batch})
    check!(sequences(post_recovery_batch) == [4], {:post_recovery_batch, post_recovery_batch})

    %{
      "gap_reason" => gap["payload"]["reason"],
      "snapshot_sequence" => snapshot["payload"]["snapshot_sequence"],
      "suffix_sequences" => sequences(suffix),
      "suffix_through_sequence" => suffix["payload"]["through_sequence"],
      "owner_sequence" => owner.sequence,
      "restored_equals_owner" => restored == owner,
      "receipt_through_sequence" => receipt["payload"]["through_sequence"],
      "post_recovery_incremental_sequences" => sequences(post_recovery_batch),
      "ordinary_incremental_sequences" => [sequences(first_batch), sequences(next_batch)],
      "ordinary_envelope_types" => ordinary_types
    }
  end

  defp lifecycle_and_cleanup do
    suffix = System.unique_integer([:positive, :monotonic])

    names = [
      name: :"m2e36-sup-#{suffix}",
      registry: :"m2e36-reg-#{suffix}",
      sessions: :"m2e36-sessions-#{suffix}"
    ]

    {:ok, supervisor} = Jido.Console.Session.Supervisor.start_link(names)
    session = Identity.new!(:session)
    {:ok, server} = Server.ensure_started(session.id, registry: names[:registry], supervisor: names[:sessions])
    client = Identity.new!(:client, session_id: session.id)
    {:ok, %{attachment: first}} = Server.attach(server, client)
    :ok = Server.detach(server, client)
    {:ok, %{attachment: second}} = Server.attach(server, client)
    check!(first.id != second.id, {:attachment_not_replaced, first, second})
    check!(Process.alive?(server), :server_stopped_on_detach)

    {:error, :artifact_start_failure} =
      Server.start_operation(server, client.id,
        start: fn _owner -> {:error, :artifact_start_failure} end,
        await: fn _request -> :unused end
      )

    test_pid = self()

    spec = [
      start: fn _owner -> {:ok, %{request_id: "m2e36-cancel"}} end,
      await: fn _request ->
        send(test_pid, {:m2e36_awaiting, self()})

        receive do
          {:m2e36_finish, result} -> result
        end
      end,
      cancel: fn _request, _opts -> {:ok, :cancelled} end
    ]

    {:ok, request} = Server.start_operation(server, client.id, spec)
    await_worker = receive_message!(:m2e36_awaiting)
    {:ok, :cancelled} = Server.cancel_request_wait(server, client.id, request, [], 1_000)
    send(await_worker, {:m2e36_finish, {:error, :cancelled}})
    {:error, :cancelled} = Server.await_request(server, request, 1_000)
    {:ok, %{active_request: nil}} = Server.runtime_info(server, client.id)

    worker = Identity.new!(:worker, session_id: session.id)
    drain = worker |> then(&Drain.queue(Drain.new(), &1)) |> then(&Drain.activate(&1, worker, ["child"]))
    drain = Drain.start(drain, worker)
    {:ok, parent_first} = Drain.collect(drain, worker, worker.id)
    check!(not Drain.complete?(parent_first), :drain_completed_before_child)
    {:ok, drained} = Drain.collect(parent_first, worker, "child")
    check!(Drain.complete?(drained), :drain_incomplete)

    cancellation_drain = Drain.activate(Drain.new(), worker, [])
    cancellation = worker |> Cancellation.request(cancellation_drain) |> Cancellation.saving()
    {:ok, cancellation_drain} = Drain.collect(cancellation.drain, worker, worker.id)
    cancellation = %{cancellation | drain: cancellation_drain}
    {:ok, cancelled} = Cancellation.complete(cancellation)
    check!(cancelled.status == :cancelled, {:cancellation_status, cancelled.status})

    :ok = Server.detach(server, client)
    :ok = Server.stop(server)
    check!(not Process.alive?(server), :server_cleanup_failed)
    :ok = Supervisor.stop(supervisor)

    %{
      "detach_kept_owner_alive" => true,
      "attachment_replaced" => first.id != second.id,
      "typed_start_failure" => "artifact_start_failure",
      "cancel_result" => "cancelled",
      "active_request_after_cancel" => nil,
      "parent_first_drain_complete" => false,
      "exact_drain_complete" => true,
      "cancellation_status" => Atom.to_string(cancelled.status),
      "server_stopped" => not Process.alive?(server)
    }
  end

  defp current_client_parity do
    parity = Jido.Console.TestSupport.CurrentClientParity
    fixture = parity.fixture!()

    surface_results = Map.new(parity.surfaces(), &{&1, parity.run_surface!(&1, fixture)})
    ledgers = surface_results |> Map.values() |> Enum.map(& &1.ledger)
    fingerprints = surface_results |> Map.values() |> Enum.map(& &1.fingerprint) |> Enum.uniq()
    effects = surface_results |> Map.values() |> Enum.map(& &1.side_effects) |> Enum.uniq()

    check!(Enum.uniq(ledgers) == [surface_results.tui.ledger], :surface_ledger_mismatch)
    check!(fingerprints == [fixture["expected_fingerprint"]], {:fingerprints, fingerprints})
    check!(length(effects) == 1, {:side_effects, effects})

    control = Map.new(parity.surfaces(), &{&1, parity.control_surface!(&1, fixture)})
    lifecycle = Map.new(parity.surfaces(), &{&1, parity.lifecycle_surface!(&1, fixture)})

    check!(
      control.tui == control.automation and control.tui == control.text and control.tui == control.json,
      :control_mismatch
    )

    check!(
      lifecycle.tui == lifecycle.automation and lifecycle.tui == lifecycle.text and
        lifecycle.tui == lifecycle.json,
      :lifecycle_mismatch
    )

    frame = parity.run_tui_entry!(fixture)
    check!(String.contains?(frame, fixture["content"]), :tui_content_missing)
    check!(String.contains?(frame, fixture["tool"]["operation"]), :tui_tool_missing)

    automation = parity.run_automation_paths!(fixture)

    Enum.each(automation, fn {_path, outcome} ->
      check!(outcome.record["execution"]["status"] == "ok", {:automation_execution, outcome})
      check!(outcome.record["evaluation"]["status"] == "passed", {:automation_evaluation, outcome})
      check!(outcome.record["capability_replay"]["status"] == "matched", {:automation_replay, outcome})
    end)

    %{
      "fixture_version" => fixture["version"],
      "surfaces" => Enum.map(parity.surfaces(), &Atom.to_string/1),
      "expected_types" => fixture["expected_types"],
      "ledger_fingerprint" => hd(fingerprints),
      "same_ledger" => true,
      "same_side_effects" => true,
      "control_types" => control.tui.types,
      "control_result" => control.tui.control,
      "control_terminal" => control.tui.terminal,
      "lifecycle" => %{
        "gap" => lifecycle.tui.gap,
        "recovery" => lifecycle.tui.recovery,
        "suffix" => lifecycle.tui.suffix,
        "receipt" => lifecycle.tui.receipt,
        "stale_completion" => inspect(lifecycle.tui.stale_completion),
        "detached" => inspect(lifecycle.tui.detached)
      },
      "public_tui_entry" => "pass",
      "automation_paths" => %{
        "eval" => automation.eval.record["evaluation"]["status"],
        "run" => automation.run.record["evaluation"]["status"]
      },
      "live_provider_calls" => false
    }
  end

  defp raw_path_guard do
    tui_paths =
      ["lib/jido_console/cli/tui.ex"] ++
        Path.wildcard("lib/jido_console/cli/tui/*.ex") ++
        ["lib/jido_console/session/client/tui.ex"]

    legacy_owner_paths = [
      "lib/jido_console/session/server.ex",
      "lib/jido_console/session/delivery.ex",
      "lib/jido_console/session/recovery.ex",
      "lib/jido_console/session/client/local.ex"
    ]

    production_paths = Path.wildcard("lib/**/*.ex")
    fixture = "test/fixtures/session/legacy_tui_client_path.fixture"

    :ok = Boundary.check(tui_paths)
    [] = Boundary.legacy_path_violations(legacy_owner_paths)

    ingresses =
      production_paths
      |> Boundary.jidoka_ingresses()
      |> Enum.map(&Map.take(&1, [:path, :function]))

    expected_ingress = [%{path: "lib/jido_console/session/server.ex", function: {:handle_info, 2}}]
    check!(ingresses == expected_ingress, {:raw_ingresses, ingresses})

    violations = Boundary.violations([fixture])
    legacy = Boundary.legacy_path_violations([fixture])
    check!(match?({:error, {:client_boundary_bypass, _}}, Boundary.check([fixture])), :guard_failed_open)
    check!(Enum.any?(violations, &(&1.kind == :forbidden_module)), :missing_module_violation)
    check!(Enum.any?(violations, &(&1.kind == :raw_message)), :missing_raw_violation)
    check!(Enum.any?(legacy, &(&1.kind == :legacy_option)), :missing_option_violation)
    check!(Enum.any?(legacy, &(&1.kind == :legacy_function)), :missing_function_violation)
    check!(Enum.any?(legacy, &(&1.kind == :legacy_facade)), :missing_facade_violation)

    parity_boundary = Jido.Console.TestSupport.ClientParityBoundary

    parity_production_paths = [
      "lib/jido_console/cli/tui.ex",
      "lib/jido_console/session/client/tui.ex",
      "lib/jido_console/session/client/automation.ex",
      "lib/jido_console/session/client/text.ex",
      "lib/jido_console/session/client/json.ex"
    ]

    parity_proof_paths = [
      "test/support/current_client_parity.ex",
      "test/jido_console/session/parity_test.exs"
    ]

    raw_violations =
      for path <- parity_production_paths,
          token <- parity_boundary.raw_violations(File.read!(path)),
          do: {path, token}

    oracle_violations =
      for path <- parity_proof_paths,
          token <- parity_boundary.oracle_violations(File.read!(path)),
          do: {path, token}

    check!(raw_violations == [], {:parity_raw_violations, raw_violations})
    check!(oracle_violations == [], {:parity_oracle_violations, oracle_violations})

    deliberate = "receive do {:jidoka, event} -> Session.Server.snapshot(event) end"
    deliberate_violations = parity_boundary.raw_violations(deliberate)
    check!(deliberate_violations == ["{:jidoka,", "Session.Server"], :parity_guard_failed_open)

    %{
      "tui_boundary_violations" => 0,
      "legacy_owner_violations" => 0,
      "approved_ingresses" => [
        %{"path" => "lib/jido_console/session/server.ex", "function" => "handle_info/2"}
      ],
      "deliberate_fixture_rejected" => true,
      "parity_raw_violations" => 0,
      "parity_oracle_violations" => 0,
      "parity_deliberate_tokens" => deliberate_violations
    }
  end

  defp receive_message!(tag) do
    receive do
      {^tag, value} -> value
    after
      1_000 -> raise "missing #{inspect(tag)}"
    end
  end

  defp delivery(opts \\ []) do
    Delivery.new(
      Keyword.merge(
        [
          session_id: @session_id,
          client_id: @client_id,
          attachment_id: @attachment_id,
          token_secret: String.duplicate("m", 32)
        ],
        opts
      )
    )
  end

  defp event(sequence) do
    type = if sequence == 1, do: "run_started", else: "model_delta"

    attrs = %{
      type: type,
      id: "m2e36-event-#{sequence}",
      session_id: @session_id,
      sequence: sequence,
      durability: "process",
      sensitivity: "public",
      origin: %{kind: "session", actor_id: @session_id},
      trust: %{evidence: "m2e36", policy: "m2e36"},
      identities: [%{"kind" => "session", "id" => @session_id, "session_id" => @session_id}],
      run_id: "m2e36-run"
    }

    attrs =
      if type == "run_started",
        do: Map.put(attrs, :turn_id, "m2e36-turn"),
        else: Map.put(attrs, :text, "delta-#{sequence}")

    {:ok, event} = Event.classify(attrs)
    event
  end

  defp sequences(envelope) do
    envelope["payload"]["events"]
    |> Enum.map(& &1["payload"]["sequence"])
  end

  defp stringify_measurements(measurements) do
    measurements
    |> stringify_map()
    |> Map.update!("status", &Atom.to_string/1)
  end

  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp check!(true, _reason), do: :ok
  defp check!(false, reason), do: raise("M2-E36 artifact proof failed: #{inspect(reason)}")
end

Jido.Console.M2E36ArtifactProof.run()
