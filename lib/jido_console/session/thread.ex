defmodule Jido.Console.Session.Thread do
  @moduledoc "State transitions and effects for one live thread owner."

  alias Jido.Console.Session.{Command, Event, JidokaBridge, Queue, Recovery, ThreadResources, View}
  alias Jido.Console.Storage
  alias Jidoka.Session.{Data, Store}

  @doc "Loads one thread and completes its recovery barrier."
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    resources_module = Keyword.get(opts, :resources_module, ThreadResources)
    storage_opts = Keyword.take(opts, [:writer, :deadline])
    store = Keyword.get(opts, :store, Storage.session_store(storage_opts))

    with {:ok, resources} <- resources_module.new(thread_id, Keyword.get(opts, :agent, Jido.Console.DefaultAgent), opts),
         {:ok, session} <- ensure_session(thread_id, resources_module.base_spec(resources), store),
         {:ok, open} <- Storage.open_thread_items(thread_id, storage_opts),
         {:ok, session, status, wake_at} <-
           Recovery.reconcile(thread_id, session, open, store, storage_opts, now_ms(opts)),
         {:ok, history} <- Storage.thread_events(thread_id, storage_opts) do
      state = %{
        thread_id: thread_id,
        store: store,
        storage_opts: storage_opts,
        task_supervisor: Keyword.get(opts, :tasks, Jido.Console.Session.TaskSupervisor),
        bridge_module: Keyword.get(opts, :bridge_module, JidokaBridge),
        resources_module: resources_module,
        resources: resources,
        options: opts,
        status: status,
        session: session,
        history: history.events,
        history_truncated?: history.history_truncated?,
        queue: Queue.new(Keyword.get(opts, :queue_limit, 32)),
        active: nil,
        bridge: nil,
        partial: [],
        partial_publish_ref: nil,
        partial_publish_token: nil,
        partial_publish_run_ref: nil,
        review: nil,
        subscribers: %{},
        monitors: %{},
        revision: 0,
        wake_ref: nil,
        error: nil
      }

      {:ok, schedule_recovery(state, wake_at)}
    end
  end

  @doc "Runs one validated command and returns a GenServer reply tuple."
  @spec command(Command.t(), map()) :: {:reply, term(), map()}
  def command(%Command{type: :submit} = command, state), do: submit(command, state)
  def command(%Command{type: :cancel} = command, state), do: cancel(command, state)
  def command(%Command{type: type} = command, state) when type in [:approve, :deny], do: decide(command, state)
  def command(%Command{type: :remove} = command, state), do: remove(command, state)
  def command(%Command{type: :status}, state), do: {:reply, {:ok, View.from_thread(state)}, state}

  def command(%Command{type: :history, payload: payload}, state) do
    opts = [
      before_sequence: Map.get(payload, "before_sequence", Map.get(payload, :before_sequence)),
      limit: Map.get(payload, "limit", Map.get(payload, :limit, 200))
    ]

    {:reply, Storage.thread_events(state.thread_id, state.storage_opts ++ opts), state}
  end

  @doc "Starts the active prompt after resource preparation."
  @spec start_active(map()) :: map()
  def start_active(state) do
    module = state.resources_module

    with {:ok, resources, session} <- module.prepare(state.resources, state.session),
         {:ok, session} <- Store.put_session(state.store, session),
         {:ok, prompt, context} <- module.prepare_prompt(resources, state.active.text, state.active.context) do
      state = %{state | resources: resources, session: session}
      start_bridge(%{state | active: %{state.active | text: prompt, context: context}}, :prompt, nil)
    else
      {:error, reason} -> fail_start(state, {:resource_preparation_failed, reason}, false)
    end
  end

  @doc "Completes the bridge handshake and starts work only after its durable start."
  @spec bridge_linked(map(), pid(), reference()) :: map()
  def bridge_linked(%{bridge: %{pid: pid, run_ref: run_ref, kind: :prompt}} = state, pid, run_ref) do
    case append_event(state, Event.for_item(state, state.active, "prompt_started", %{})) do
      {:ok, state, _event} ->
        send(pid, {:begin, run_ref})
        View.publish(%{state | status: :running})

      {:error, reason, state} ->
        Process.unlink(pid)
        Process.exit(pid, :shutdown)
        fail_start(%{state | bridge: nil}, {:prompt_started_failed, reason}, uncertain_write?(reason))
    end
  end

  def bridge_linked(%{bridge: %{pid: pid, run_ref: run_ref}} = state, pid, run_ref) do
    send(pid, {:begin, run_ref})
    View.publish(%{state | status: :running})
  end

  def bridge_linked(state, _pid, _run_ref), do: state

  @doc "Stores the private request handle and applies one early cancel."
  @spec bridge_handle(map(), pid(), reference(), String.t(), term()) :: map()
  def bridge_handle(state, pid, run_ref, request_id, handle) do
    if current_bridge?(state, pid, run_ref, request_id) do
      state = put_in(state, [:bridge, :handle], handle)
      if state.bridge.pending_cancel?, do: request_cancel(state), else: state
    else
      state
    end
  end

  @doc "Adds a fenced live projection to the current partial View."
  @spec bridge_event(map(), reference(), String.t(), term()) :: map()
  def bridge_event(state, run_ref, request_id, event) do
    if current_run?(state, run_ref, request_id) do
      case Jidoka.project_events(event) do
        {:ok, projected} ->
          state
          |> Map.update!(:partial, &[projected | &1])
          |> schedule_partial_publish(run_ref)

        {:error, _reason} ->
          state
      end
    else
      state
    end
  end

  @doc "Finalizes a fenced bridge result before advancing the FIFO."
  @spec bridge_result(map(), pid(), reference(), String.t(), term()) :: map()
  def bridge_result(state, pid, run_ref, request_id, result) do
    if current_bridge?(state, pid, run_ref, request_id) do
      Process.unlink(pid)

      state
      |> flush_partial()
      |> Map.put(:bridge, nil)
      |> finish_result(result)
    else
      state
    end
  end

  @doc "Publishes the latest complete partial View for one current timer."
  @spec publish_partial(map(), reference(), reference()) :: map()
  def publish_partial(state, run_ref, token) do
    if current_run?(state, run_ref, active_request_id(state)) and
         state.partial_publish_run_ref == run_ref and state.partial_publish_token == token do
      state
      |> cancel_partial_publish()
      |> View.publish()
    else
      state
    end
  end

  @doc "Returns true when a PID is the active linked bridge."
  @spec bridge_pid?(map(), pid()) :: boolean()
  def bridge_pid?(%{bridge: %{pid: pid}}, pid), do: true
  def bridge_pid?(_state, _pid), do: false

  @doc "Re-runs the durable recovery barrier."
  @spec reconcile(map()) :: {:ok, map()} | {:error, term(), map()}
  def reconcile(state) do
    now = now_ms(state.options)

    with {:ok, session} <- Store.get_session(state.store, state.thread_id),
         {:ok, open} <- Storage.open_thread_items(state.thread_id, state.storage_opts),
         {:ok, session, status, wake_at} <-
           Recovery.reconcile(state.thread_id, session, open, state.store, state.storage_opts, now),
         {:ok, history} <- Storage.thread_events(state.thread_id, state.storage_opts) do
      state = %{
        state
        | session: session,
          status: status,
          history: history.events,
          history_truncated?: history.history_truncated?,
          error: nil
      }

      {:ok, schedule_recovery(state, wake_at)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Closes resources owned by this thread."
  @spec close(map()) :: term()
  def close(state), do: state.resources_module.close(state.resources)

  @doc "Moves the thread to an unavailable state and publishes its View."
  @spec unavailable(map(), term()) :: map()
  def unavailable(state, reason),
    do: View.publish(%{state | status: :unavailable, error: Event.json(Jidoka.error_to_map(reason))})

  defp submit(command, state) do
    digest = Command.digest(command)
    item = Command.item(command, digest)

    case Command.find_item(state, command.queue_item_id) do
      %{digest: ^digest} = existing ->
        {:reply, {:ok, Command.acceptance(existing, true, state)}, state}

      nil ->
        if state.active && Queue.full?(state.queue),
          do: retry_closed_or_full(command, digest, state),
          else: accept_new(item, state)

      _conflict ->
        {:reply, {:error, :command_conflict}, state}
    end
  end

  defp accept_new(item, state) do
    queued = Event.for_item(state, item, "prompt_queued", %{"input" => item.text, "command_digest" => item.digest})

    case append_event(state, queued) do
      {:ok, state, %{duplicate: true}} ->
        retry_closed(Command.from_item(item, state.thread_id), item.digest, state)

      {:ok, state, %{duplicate: false}} when not is_nil(state.active) ->
        case Queue.push(state.queue, item) do
          {:ok, queue} ->
            {:reply, {:ok, Command.acceptance(item, false, state)}, View.publish(%{state | queue: queue})}

          {:error, reason} ->
            {:reply, {:error, reason}, unavailable(state, reason)}
        end

      {:ok, state, %{duplicate: false}} ->
        state = View.publish(%{state | active: item, status: :idle})
        send(self(), :start_active)
        {:reply, {:ok, Command.acceptance(item, false, state)}, state}

      {:error, {:event_conflict, _id}, state} ->
        retry_closed(Command.from_item(item, state.thread_id), item.digest, state)

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp retry_closed_or_full(command, digest, state),
    do: retry_reply(retry_events(command, digest, state), state, :queue_full)

  defp retry_closed(command, digest, state),
    do: retry_reply(retry_events(command, digest, state), state, :command_conflict)

  defp retry_reply({:ok, accepted}, state, _missing), do: {:reply, {:ok, accepted}, state}
  defp retry_reply(:not_found, state, missing), do: {:reply, {:error, missing}, state}
  defp retry_reply(:conflict, state, _missing), do: {:reply, {:error, :command_conflict}, state}
  defp retry_reply({:error, reason}, state, _missing), do: {:reply, {:error, reason}, state}

  defp retry_events(command, digest, state) do
    case Storage.request_events(state.thread_id, command.request_id, state.storage_opts) do
      {:ok, [%Event{type: "prompt_queued"} = queued | _events]} ->
        if queued.queue_item_id == command.queue_item_id and queued.payload["command_digest"] == digest do
          {:ok,
           %{
             thread_id: state.thread_id,
             queue_item_id: queued.queue_item_id,
             request_id: queued.request_id,
             duplicate: true,
             status: :closed
           }}
        else
          :conflict
        end

      {:ok, []} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel(command, %{status: :review} = state) do
    reply =
      if active_request_id(state) == command.request_id, do: {:error, :review_pending}, else: {:error, :stale_request}

    {:reply, reply, state}
  end

  defp cancel(command, state) do
    cond do
      active_request_id(state) != command.request_id ->
        {:reply, {:error, :stale_request}, state}

      is_nil(state.bridge) ->
        pending = %{pid: nil, run_ref: nil, handle: nil, pending_cancel?: true, kind: :pending}
        {:reply, {:ok, :requested}, %{state | bridge: pending}}

      is_nil(state.bridge.handle) ->
        {:reply, {:ok, :requested}, put_in(state, [:bridge, :pending_cancel?], true)}

      true ->
        case Jidoka.cancel(state.bridge.handle) do
          {:ok, _cancellation} -> {:reply, {:ok, :requested}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp decide(command, %{status: :review, review: %{id: review_id}} = state) do
    if active_request_id(state) == command.request_id and review_id == command.review_id,
      do: {:reply, {:ok, :requested}, start_bridge(state, command.type, state.review.interrupt_id)},
      else: {:reply, {:error, :stale_review}, state}
  end

  defp decide(_command, state), do: {:reply, {:error, :review_not_pending}, state}

  defp remove(command, state) do
    case Queue.remove(state.queue, command.queue_item_id) do
      {:ok, nil, _queue} ->
        {:reply, {:ok, :removed}, state}

      {:ok, item, queue} ->
        case append_event(state, Event.for_item(state, item, "prompt_removed", %{})) do
          {:ok, state, _event} -> {:reply, {:ok, :removed}, View.publish(%{state | queue: queue})}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp start_bridge(state, kind, review_id) do
    state = cancel_partial_publish(state)
    run_ref = make_ref()
    owner = self()
    action = bridge_action(state, kind, review_id)
    pending_cancel? = not is_nil(state.bridge) and state.bridge.pending_cancel?

    case start_bridge_task(state.task_supervisor, fn -> state.bridge_module.run(owner, run_ref, action) end) do
      {:ok, pid} ->
        bridge = %{pid: pid, run_ref: run_ref, handle: nil, pending_cancel?: pending_cancel?, kind: kind}
        View.publish(%{state | bridge: bridge, status: :starting})

      {:error, reason} ->
        fail_start(state, {:bridge_start_failed, reason}, false)
    end
  end

  defp bridge_action(state, :prompt, _review_id) do
    %{
      kind: :prompt,
      thread_id: state.thread_id,
      request_id: state.active.request_id,
      prompt: state.active.text,
      context: state.active.context,
      runtime_opts: state.resources_module.runtime_opts(state.resources),
      store: state.store
    }
  end

  defp bridge_action(state, decision, review_id) do
    %{
      kind: decision,
      thread_id: state.thread_id,
      session: state.session,
      request_id: state.active.request_id,
      review_id: review_id,
      context: state.active.context,
      runtime_opts: state.resources_module.runtime_opts(state.resources),
      store: state.store
    }
  end

  defp request_cancel(state) do
    case Jidoka.cancel(state.bridge.handle) do
      {:ok, _cancellation} -> put_in(state, [:bridge, :pending_cancel?], false)
      {:error, _reason} -> state
    end
  end

  defp finish_result(state, {:hibernate, %Data{} = session, _snapshot}) do
    case Jidoka.pending_reviews(session) do
      {:ok, [review | _rest]} ->
        present_review(%{state | session: session}, review)

      {:ok, []} ->
        finish_terminal(%{state | session: session}, "prompt_failed", %{"error" => "unexpected_hibernation"})

      {:error, reason} ->
        finish_terminal(%{state | session: session}, "prompt_failed", %{
          "error" => Event.json(Jidoka.error_to_map(reason))
        })
    end
  end

  defp finish_result(state, {:ok, %Data{} = session, result}),
    do:
      finish_terminal(%{state | session: session}, "prompt_succeeded", %{"result" => Event.json(Jidoka.project(result))})

  defp finish_result(state, {:cancelled, cancellation}),
    do: finish_loaded(state, "prompt_cancelled", %{"error" => Event.json(Jidoka.error_to_map(cancellation))})

  defp finish_result(state, {:error, reason}),
    do: finish_loaded(state, "prompt_failed", %{"error" => Event.json(Jidoka.error_to_map(reason))})

  defp finish_result(state, result),
    do: finish_loaded(state, "prompt_failed", %{"error" => Event.json(Jidoka.error_to_map({:invalid_result, result}))})

  defp present_review(state, review) do
    projected = review |> Jidoka.project() |> Event.json()

    case append_event(
           state,
           Event.for_item(
             state,
             state.active,
             "review_presented",
             %{"review" => projected},
             state.session.revision,
             review.id
           )
         ) do
      {:ok, state, _event} ->
        review_state = %{id: review.id, interrupt_id: review.interrupt_id, data: projected}

        state
        |> clear_partial()
        |> Map.merge(%{status: :review, review: review_state})
        |> View.publish()

      {:error, reason, state} ->
        unavailable(%{state | status: :finishing}, reason)
    end
  end

  defp finish_loaded(state, type, payload) do
    case Store.get_session(state.store, state.thread_id) do
      {:ok, session} -> finish_terminal(%{state | session: session}, type, payload)
      {:error, reason} -> unavailable(%{state | status: :finishing}, reason)
    end
  end

  defp finish_terminal(state, type, payload) do
    case append_event(
           %{state | status: :finishing},
           Event.for_item(state, state.active, type, payload, state.session.revision)
         ) do
      {:ok, state, _event} ->
        state =
          state
          |> clear_partial()
          |> Map.merge(%{status: :idle, active: nil, review: nil, error: nil})
          |> View.publish()

        start_next(state)

      {:error, reason, state} ->
        unavailable(state, reason)
    end
  end

  defp fail_start(state, reason, true), do: unavailable(%{state | status: :finishing}, reason)

  defp fail_start(state, reason, false),
    do: finish_terminal(state, "prompt_failed", %{"error" => Event.json(Jidoka.error_to_map(reason))})

  defp start_next(state) do
    case Queue.pop(state.queue) do
      {:ok, item, queue} ->
        state = %{state | active: item, queue: queue}
        send(self(), :start_active)
        state

      {:error, :queue_empty} ->
        state
    end
  end

  defp append_event(state, event) do
    case Storage.append_thread_event(event, state.storage_opts) do
      {:ok, %{event: _stored, duplicate: true} = result} ->
        {:ok, state, result}

      {:ok, %{event: stored, duplicate: false} = result} ->
        history = Enum.take((state.history ++ [stored]) |> Enum.reverse(), 200) |> Enum.reverse()

        {:ok,
         %{state | history: history, history_truncated?: state.history_truncated? or length(state.history) + 1 > 200},
         result}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp schedule_partial_publish(%{partial_publish_token: nil} = state, run_ref) do
    token = make_ref()
    interval = Keyword.get(state.options, :partial_publish_interval_ms, 16)
    timer = Process.send_after(self(), {:publish_partial, run_ref, token}, interval)

    %{state | partial_publish_ref: timer, partial_publish_token: token, partial_publish_run_ref: run_ref}
  end

  defp schedule_partial_publish(state, _run_ref), do: state

  defp flush_partial(%{partial_publish_token: nil} = state), do: state

  defp flush_partial(state) do
    state
    |> cancel_partial_publish()
    |> View.publish()
  end

  defp clear_partial(state) do
    state
    |> cancel_partial_publish()
    |> Map.put(:partial, [])
  end

  defp cancel_partial_publish(state) do
    if state.partial_publish_ref, do: Process.cancel_timer(state.partial_publish_ref)

    %{state | partial_publish_ref: nil, partial_publish_token: nil, partial_publish_run_ref: nil}
  end

  defp schedule_recovery(state, nil), do: state

  defp schedule_recovery(state, expires_at_ms) do
    if state.wake_ref, do: Process.cancel_timer(state.wake_ref)
    %{state | wake_ref: Process.send_after(self(), :reconcile, max(expires_at_ms - now_ms(state.options), 0))}
  end

  defp active_request_id(%{active: %{request_id: request_id}}), do: request_id
  defp active_request_id(_state), do: nil

  defp current_bridge?(%{bridge: %{pid: pid, run_ref: run_ref}} = state, pid, run_ref, request_id),
    do: active_request_id(state) == request_id

  defp current_bridge?(_state, _pid, _run_ref, _request_id), do: false

  defp current_run?(%{bridge: %{run_ref: run_ref}} = state, run_ref, request_id),
    do: active_request_id(state) == request_id

  defp current_run?(_state, _run_ref, _request_id), do: false

  defp ensure_session(thread_id, spec, store) do
    case Store.get_session(store, thread_id) do
      {:ok, session} ->
        {:ok, session}

      {:error, {:session_not_found, ^thread_id}} ->
        with {:ok, session} <- Data.start(spec, session_id: thread_id) do
          Store.put_session(store, session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp uncertain_write?({:timeout_unknown, _id}), do: true
  defp uncertain_write?(_reason), do: false

  defp start_bridge_task(supervisor, fun) do
    Task.Supervisor.start_child(supervisor, fun)
  catch
    :exit, _reason -> {:error, :bridge_supervisor_unavailable}
  end

  defp now_ms(opts), do: if(is_function(opts[:clock], 0), do: opts[:clock].(), else: System.system_time(:millisecond))
end
