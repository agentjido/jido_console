defmodule Jido.Console.Session.RecoveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Recovery
  alias Jidoka.Agent
  alias Jidoka.Session.{Data, Transitions}
  alias Jidoka.Turn

  defmodule RecoveryStore do
    @behaviour Jidoka.Session.Store

    def put_session(session, _opts), do: {:ok, session}
    def get_session(_session_id, opts), do: {:ok, Keyword.fetch!(opts, :session)}
    def list_sessions(_opts), do: {:ok, []}

    def claim_session(_session_id, _request, _opts), do: {:error, :not_used}
    def claim_resume(_session_id, _opts), do: {:error, :not_used}

    def recover_session(_session_id, opts) do
      case Keyword.fetch!(opts, :mode) do
        :missing_lease -> {:ok, %{Keyword.fetch!(opts, :session) | lease: nil}}
        :error -> {:error, :recovery_store_failed}
      end
    end

    def checkpoint_session(_session_id, _lease_id, _snapshot, _opts), do: {:error, :not_used}
    def commit_session(_session_id, _lease_id, session, _opts), do: {:ok, session}
    def renew_session(_session_id, _lease_id, _opts), do: {:error, :not_used}
  end

  test "rejects a running lease when product history has no started item" do
    running = running_session()
    queued = item(started: nil)

    assert {:error, {:recovery_started_item_missing, "request-1"}} =
             Recovery.reconcile(
               running.session_id,
               running,
               [queued],
               {RecoveryStore, session: running, mode: :error},
               [writer: :missing_recovery_writer, deadline: 1],
               100
             )
  end

  test "reports missing and failed replacement leases" do
    running = running_session()
    active = item(started: %{})
    storage_opts = [writer: :missing_recovery_writer, deadline: 1]

    assert {:error, :recovery_lease_missing} =
             Recovery.reconcile(
               running.session_id,
               running,
               [active],
               {RecoveryStore, session: running, mode: :missing_lease},
               storage_opts,
               200
             )

    assert {:error, :recovery_store_failed} =
             Recovery.reconcile(
               running.session_id,
               running,
               [active],
               {RecoveryStore, session: running, mode: :error},
               storage_opts,
               200
             )
  end

  test "fails closed when interrupted product history cannot be persisted" do
    terminal = new_session() |> Data.put_error(:owner_replaced)
    open = [item(started: %{})]

    assert {:error, :storage_unavailable} =
             Recovery.reconcile(
               terminal.session_id,
               terminal,
               open,
               {RecoveryStore, session: terminal, mode: :error},
               [writer: :missing_recovery_writer, deadline: 1],
               200
             )
  end

  defp running_session do
    request = Turn.Request.new!(input: "recover", request_id: "request-1")

    {:ok, running} =
      Transitions.claim(new_session(), request,
        now_ms: 100,
        lease_ttl_ms: 10,
        owner_id: "old-owner",
        id_generator: fn "lease" -> "lease-1" end
      )

    running
  end

  defp new_session do
    spec =
      Agent.Spec.new!(
        id: "recovery-test-agent",
        instructions: "Test recovery failures.",
        model: %{provider: :test, id: "model"}
      )

    {:ok, session} = Data.start(spec, session_id: "recovery-thread")
    session
  end

  defp item(overrides) do
    Map.merge(
      %{
        queue_item_id: "item-1",
        request_id: "request-1",
        queued: %{},
        started: nil,
        reviews: [],
        events: []
      },
      Map.new(overrides)
    )
  end
end
