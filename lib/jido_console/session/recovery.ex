defmodule Jido.Console.Session.Recovery do
  @moduledoc "Repairs product prompt history from durable Jidoka state."

  alias Jido.Console.SafeDisplay
  alias Jido.Console.Session.Event
  alias Jido.Console.Storage
  alias Jidoka.Session.{Data, Lease, Store}

  @terminal_statuses [:finished, :cancelled, :error]

  @doc "Reconciles all open product prompts before a thread accepts work."
  @spec reconcile(String.t(), Data.t(), [map()], Store.store(), keyword(), non_neg_integer()) ::
          {:ok, Data.t(), :idle | :reconciling, non_neg_integer() | nil} | {:error, term()}
  def reconcile(_thread_id, %Data{} = session, [], _store, _storage_opts, _now_ms),
    do: {:ok, session, :idle, nil}

  def reconcile(thread_id, %Data{} = session, open, store, storage_opts, now_ms) do
    active = Enum.find(open, & &1.started)

    case recovery_action(session, active, now_ms) do
      {:wait, expires_at_ms} ->
        {:ok, session, :reconciling, expires_at_ms}

      {:terminal, type, payload} ->
        with {:ok, _event} <- close_item(thread_id, active, type, payload, session.revision, storage_opts),
             {:ok, _events} <- close_others(thread_id, open -- [active], session.revision, storage_opts) do
          {:ok, session, :idle, nil}
        end

      :interrupt ->
        with {:ok, session} <- interrupt_session(session, store, now_ms),
             {:ok, _events} <- close_others(thread_id, open, session.revision, storage_opts) do
          {:ok, session, :idle, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recovery_action(%Data{status: status} = session, %{request_id: request_id}, _now_ms)
       when status in @terminal_statuses do
    if last_request_id(session) == request_id do
      {type, payload} = terminal_event(session)
      {:terminal, type, payload}
    else
      :interrupt
    end
  end

  defp recovery_action(%Data{status: :running, lease: %Lease{} = lease}, %{request_id: request_id}, now_ms) do
    cond do
      lease.request_id != request_id -> {:error, {:recovery_request_mismatch, request_id, lease.request_id}}
      Lease.expired?(lease, now_ms) -> :interrupt
      true -> {:wait, lease.expires_at_ms}
    end
  end

  defp recovery_action(%Data{status: :running, lease: %Lease{} = lease}, nil, _now_ms),
    do: {:error, {:recovery_started_item_missing, lease.request_id}}

  defp recovery_action(%Data{}, _active, _now_ms), do: :interrupt

  defp interrupt_session(%Data{status: :running, lease: %Lease{}} = session, store, now_ms) do
    with {:ok, recovered} <- Store.recover_session(store, session.session_id, clock: fn -> now_ms end),
         %Lease{lease_id: lease_id} <- recovered.lease,
         interrupted = Data.put_error(recovered, :owner_replaced),
         {:ok, committed} <-
           Store.commit_session(store, session.session_id, lease_id, interrupted, clock: fn -> now_ms end) do
      {:ok, committed}
    else
      nil -> {:error, :recovery_lease_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interrupt_session(%Data{} = session, store, _now_ms) do
    Store.put_session(store, Data.put_error(session, :owner_replaced))
  end

  defp close_others(thread_id, open, revision, storage_opts) do
    Enum.reduce_while(open, {:ok, []}, fn item, {:ok, events} ->
      case close_item(
             thread_id,
             item,
             "prompt_interrupted",
             %{"reason" => "owner_replaced"},
             revision,
             storage_opts
           ) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp close_item(thread_id, item, type, payload, revision, storage_opts) do
    event =
      Event.new!(
        id: Event.event_id(thread_id, item.queue_item_id, type),
        session_id: thread_id,
        queue_item_id: item.queue_item_id,
        request_id: item.request_id,
        type: type,
        payload: payload,
        jidoka_revision: revision
      )

    case Storage.append_thread_event(event, storage_opts) do
      {:ok, %{event: stored}} -> {:ok, stored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_event(%Data{status: :finished, result: result}) do
    {"prompt_succeeded", %{"result" => Event.json(Jidoka.project(result))}}
  end

  defp terminal_event(%Data{status: :cancelled, error: reason}) do
    {"prompt_cancelled", %{"error" => Event.json(SafeDisplay.to_map(reason))}}
  end

  defp terminal_event(%Data{status: :error, error: reason}) do
    {"prompt_failed", %{"error" => Event.json(SafeDisplay.to_map(reason))}}
  end

  defp last_request_id(%Data{requests: requests}) do
    case List.last(requests) do
      %{request_id: request_id} -> request_id
      _request -> nil
    end
  end
end
