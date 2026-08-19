defmodule Jido.Console.SessionClientContract do
  @moduledoc "Reusable black-box contract for renderer-neutral session drivers."

  import ExUnit.Assertions

  alias Jido.Console.Session.Client

  @doc false
  def assert_restart_safe_admissions(handle) do
    assert {:ok, sent} = Client.send(handle, "hello", idempotency_key: "contract-send")
    assert {:ok, steered} = Client.steer(handle, "now", idempotency_key: "contract-steer")
    assert {:ok, queued} = Client.queue(handle, "later", idempotency_key: "contract-queue")

    assert {:ok, removed} =
             Client.remove(handle, :follow_up, queued.identity.id, idempotency_key: "contract-remove")

    assert {:ok, removed_retry} =
             Client.remove(handle, :follow_up, queued.identity.id, idempotency_key: "contract-remove")

    assert removed_retry.receipt == removed.receipt
    assert sent.client_id == handle.client.id
    assert steered.client_id == handle.client.id
    assert sent.receipt["type"] == "input"
    assert queued.receipt["payload"]["status"] == "committed"
    assert {:ok, duplicate} = Client.send(handle, "hello", idempotency_key: "contract-send")
    assert duplicate.identity.id == sent.identity.id
    assert duplicate.receipt == sent.receipt

    assert {:error, {:idempotency_conflict, receipt_id}} =
             Client.send(handle, "changed", idempotency_key: "contract-send")

    assert receipt_id == sent.receipt["id"]
    assert {:ok, looked_up} = Client.receipt(handle, sent.receipt["payload"]["operation_id"])
    assert looked_up == sent.receipt
  end

  defmacro __using__(opts) do
    driver = Keyword.fetch!(opts, :driver)

    quote do
      use ExUnit.Case, async: true

      alias Jido.Console.Session.{Client, Envelope, Identity, Supervisor}

      setup do
        suffix = System.unique_integer([:positive])

        names = [
          name: :"contract-#{suffix}",
          registry: :"contract-reg-#{suffix}",
          sessions: :"contract-dyn-#{suffix}"
        ]

        {:ok, supervisor} = Supervisor.start_link(names)
        on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

        session = Identity.new!(:session)

        client_opts = [
          driver: unquote(driver),
          registry: names[:registry],
          supervisor: names[:sessions]
        ]

        %{session: session, client_opts: client_opts}
      end

      test "attach returns opaque exact identities and one valid bounded baseline", context do
        assert {:ok, attached} = Client.attach(context.session.id, context.client_opts)
        handle = attached.handle

        assert handle.session.id == context.session.id
        assert handle.client.session_id == context.session.id
        assert handle.attachment.session_id == context.session.id
        assert handle.protocol == "1"
        assert attached.capabilities["grants_authority"] == false
        assert {:ok, _snapshot} = Envelope.validate(attached.snapshot)
        assert attached.snapshot["type"] == "attach_snapshot"

        public = Map.from_struct(handle)
        refute Map.has_key?(public, :server)
        refute Map.has_key?(public, :snapshot)
        refute contract_live_value?(public)
        refute inspect(handle) =~ "registry"
      end

      test "reattach replaces only the exact attachment and rejects the old handle", context do
        client_id = "cli_contract"
        opts = Keyword.put(context.client_opts, :client_id, client_id)
        assert {:ok, first} = Client.attach(context.session.id, opts)
        assert {:ok, second} = Client.attach(context.session.id, opts)

        refute first.handle.attachment.id == second.handle.attachment.id
        assert {:error, :delivery_identity_mismatch} = Client.status(first.handle)
        assert {:error, :delivery_identity_mismatch} = Client.detach(first.handle)
        assert {:ok, status} = Client.status(second.handle)
        assert status["attachment_id"] == second.handle.attachment.id
      end

      test "input and output use one bounded canonical path with exact idempotent acknowledgement", context do
        assert {:ok, attached} = Client.attach(context.session.id, context.client_opts)
        handle = attached.handle

        Jido.Console.SessionClientContract.assert_restart_safe_admissions(handle)

        assert_receive {:jido_console_session, attachment_id, :output_ready}
        assert attachment_id == handle.attachment.id
        refute_receive {:jido_console_session, ^attachment_id, :output_ready}, 20

        assert {:ok, batch} = Client.output(handle)
        assert {:ok, ^batch} = Envelope.validate(batch)
        assert batch["type"] == "output_batch"
        assert Enum.count(batch["payload"]["events"], &(&1["type"] == "input_admitted")) == 3
        refute Enum.any?(batch["payload"]["events"], &(&1["type"] == "delivery_gap"))
        assert {:error, :ack_required} = Client.output(handle)

        token = batch["payload"]["acknowledgement_token"]
        assert {:ok, receipt} = Client.ack(handle, token)
        assert receipt["process_lifetime"]
        assert {:ok, ^receipt} = Client.ack(handle, token)
        assert {:error, :invalid_acknowledgement} = Client.ack(handle, "fabricated")
      end

      test "a gap stays closed through the exact three-phase recovery", context do
        opts = Keyword.put(context.client_opts, :delivery_limits, %{queue_count: 1})
        assert {:ok, attached} = Client.attach(context.session.id, opts)
        handle = attached.handle

        assert {:ok, _input} = Client.send(handle, "first", idempotency_key: "gap-first")
        assert {:ok, _input} = Client.send(handle, "second", idempotency_key: "gap-second")
        assert_receive {:jido_console_session, attachment_id, :output_ready}
        assert attachment_id == handle.attachment.id
        assert {:gap, gap} = Client.output(handle)
        refute gap["family"] == "event"

        assert {:ok, snapshot} = Client.recover(handle, gap)
        assert {:error, :delivery_recovering} = Client.output(handle)
        assert {:ok, suffix} = Client.replay(handle, snapshot["payload"]["recovery_token"])

        assert {:error, :stale_completion_token} = Client.resume(handle, "stale")
        assert {:ok, receipt} = Client.resume(handle, suffix["payload"]["completion_token"])
        assert receipt["payload"]["process_lifetime"]
        assert :empty = Client.output(handle)
      end

      test "capabilities are versioned descriptive data and cannot grant authority", context do
        required = ~w(output recover)
        opts = Keyword.put(context.client_opts, :required_capabilities, required)
        assert {:ok, attached} = Client.attach(context.session.id, opts)

        assert {:ok, capabilities} = Client.capabilities(attached.handle)
        assert capabilities["version"] == "1"
        assert capabilities["descriptive_only"]
        refute capabilities["grants_authority"]
        assert {:ok, true} = Client.supports?(attached.handle, :output)
        assert {:ok, false} = Client.supports?(attached.handle, "authority")

        missing = Keyword.put(context.client_opts, :required_capabilities, ["unknown"])

        assert {:error, {:required_capability_missing, ["unknown"]}} =
                 Client.attach(context.session.id, missing)
      end

      defp contract_live_value?(value)
           when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
           do: true

      defp contract_live_value?(value) when is_map(value),
        do: Enum.any?(value, fn {_key, item} -> contract_live_value?(item) end)

      defp contract_live_value?(value) when is_list(value),
        do: Enum.any?(value, &contract_live_value?/1)

      defp contract_live_value?(_value), do: false
    end
  end
end
