defmodule Jido.Console.Session.Thread do
  @moduledoc "State transitions and effects for one live thread owner."

  alias Jido.Console.Error
  alias Jido.Console.Models

  alias Jido.Console.Session.{
    BindingManifest,
    BindingRequest,
    Command,
    Event,
    JidokaBridge,
    Queue,
    Recovery,
    Selection,
    ThreadResources,
    View
  }

  alias Jido.Console.Storage
  alias Jidoka.Session.{Data, Store}

  @doc "Loads one thread and completes its recovery barrier."
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    resources_module = Keyword.get(opts, :resources_module, ThreadResources)
    storage_opts = Keyword.take(opts, [:writer, :deadline])
    store = Keyword.get(opts, :store, Storage.session_store(storage_opts))

    case Store.get_session(store, thread_id) do
      {:ok, %Data{} = session} ->
        with {:ok, history} <- Storage.thread_events(thread_id, storage_opts) do
          init_existing(session, history, resources_module, store, storage_opts, opts)
        end

      {:error, {:session_not_found, ^thread_id}} ->
        init_new(thread_id, resources_module, store, storage_opts, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Runs one validated command and returns a GenServer reply tuple."
  @spec command(Command.t(), map()) :: {:reply, term(), map()}
  def command(%Command{type: :submit} = command, state), do: submit(command, state)
  def command(%Command{type: :cancel} = command, state), do: cancel(command, state)
  def command(%Command{type: type} = command, state) when type in [:approve, :deny], do: decide(command, state)
  def command(%Command{type: :remove} = command, state), do: remove(command, state)
  def command(%Command{type: :select_agent} = command, state), do: select_agent(command, state)
  def command(%Command{type: :select_model} = command, state), do: select_model(command, state)

  def command(%Command{type: :select_execution_policy} = command, state),
    do: select_execution_policy(command, state)

  def command(%Command{type: :status}, state), do: {:reply, {:ok, View.from_thread(state)}, state}

  def command(%Command{type: :history, payload: payload}, state) do
    opts = [
      before_sequence: Map.get(payload, "before_sequence", Map.get(payload, :before_sequence)),
      limit: Map.get(payload, "limit", Map.get(payload, :limit, 200))
    ]

    {:reply, Storage.thread_events(state.thread_id, state.storage_opts ++ opts), state}
  end

  @doc "Checks one attach request against the authoritative owner selection."
  @spec attach_request(map(), BindingRequest.t()) :: :ok | {:error, term()}
  def attach_request(%{selection: %Selection{} = selection}, %BindingRequest{} = request),
    do: Selection.match_request(selection, request)

  @doc "Starts the active prompt after resource preparation."
  @spec start_active(map()) :: map()
  def start_active(state) do
    module = state.resources_module

    with :ok <- require_locked_binding(state),
         {:ok, resources, session} <- module.prepare(state.resources, state.session),
         {:ok, session} <- persist_runtime_session(state, resources, session),
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
  def reconcile(%{pending_lock: pending} = state) when not is_nil(pending) do
    reconcile_pending_lock(state, pending)
  end

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

  defp reconcile_pending_lock(state, pending) do
    with {:ok, session} <- Store.get_session(state.store, state.thread_id),
         {:ok, events} <-
           Storage.request_events(state.thread_id, pending.item.request_id, state.storage_opts) do
      manifest = BindingManifest.fetch(session)
      queued = Enum.find(events, &(&1.id == pending.event.id))

      case {manifest, queued} do
        {{:ok, stored_manifest}, %Event{} = event}
        when stored_manifest == pending.selection.manifest ->
          if Event.identity(event) == Event.identity(pending.event) do
            case Storage.thread_events(state.thread_id, state.storage_opts) do
              {:ok, history} ->
                state =
                  state
                  |> install_locked_selection(pending.selection, session)
                  |> Map.merge(%{
                    active: pending.item,
                    status: :idle,
                    history: history.events,
                    history_truncated?: history.history_truncated?
                  })
                  |> View.publish()

                send(self(), :start_active)
                {:ok, state}

              {:error, reason} ->
                {:error, reason, state}
            end
          else
            {:error, {:binding_lock_integrity_failed, pending.operation_id}, state}
          end

        {{:ok, %{"lock_state" => "draft"}}, nil} ->
          {:ok, View.publish(%{state | pending_lock: nil, status: :idle, error: nil})}

        _other ->
          {:error, {:binding_lock_integrity_failed, pending.operation_id}, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Closes resources owned by this thread."
  @spec close(map()) :: term()
  def close(%{resources: nil}), do: :ok
  def close(state), do: state.resources_module.close(state.resources)

  @doc "Moves the thread to an unavailable state and publishes its View."
  @spec unavailable(map(), term()) :: map()
  def unavailable(state, reason),
    do: View.publish(%{state | status: :unavailable, error: Event.json(Error.to_map(reason))})

  defp init_new(thread_id, resources_module, store, storage_opts, opts) do
    opts = Keyword.put(opts, :thread_id, thread_id)

    with {:ok, selection} <- Selection.new(opts),
         {:ok, session, persisted?} <- new_session(selection, thread_id, store),
         {:ok, resources} <- new_resources(resources_module, selection, thread_id, opts),
         {:ok, model_catalog, model} <- model_catalog(selection, opts) do
      state =
        base_state(
          thread_id,
          resources_module,
          resources,
          store,
          storage_opts,
          opts,
          selection,
          session,
          [],
          false,
          model_catalog,
          model
        )

      {:ok, %{state | session_persisted?: persisted?}}
    else
      {:error, %{__exception__: true} = error} ->
        {:error, error}

      {:error, reason} ->
        if model_configuration_reason?(reason) do
          {:error,
           Error.config_error("Unable to configure the session model", %{
             source: :model_catalog,
             reason: inspect(reason)
           })}
        else
          {:error, reason}
        end
    end
  end

  defp init_existing(session, history, resources_module, store, storage_opts, opts) do
    opts = Keyword.put(opts, :thread_id, session.session_id)

    resume_opts =
      Keyword.put(opts, :legacy_events_present?, history.events != [])

    case Selection.resume(session, resume_opts) do
      {:ok, selection} ->
        init_resumable(session, selection, resources_module, store, storage_opts, opts)

      {:rebind, selection} ->
        with {:ok, incoming} <- Selection.put_draft(selection, session),
             {:ok, adopted} <-
               Storage.adopt_binding_draft(incoming, session.revision, storage_opts) do
          init_resumable(adopted, selection, resources_module, store, storage_opts, opts)
        end

      {:blocked, selection} ->
        init_blocked(session, history, selection, resources_module, store, storage_opts, opts)
    end
  end

  defp init_resumable(session, selection, resources_module, store, storage_opts, opts) do
    with {:ok, resources} <- new_resources(resources_module, selection, session.session_id, opts),
         {:ok, model_catalog, model} <- model_catalog(selection, opts),
         {:ok, open} <- Storage.open_thread_items(session.session_id, storage_opts),
         {:ok, session, status, wake_at, active, queue} <-
           recover_owner_queue(selection, session, open, store, storage_opts, opts),
         {:ok, history} <- Storage.thread_events(session.session_id, storage_opts) do
      state =
        base_state(
          session.session_id,
          resources_module,
          resources,
          store,
          storage_opts,
          opts,
          selection,
          session,
          history.events,
          history.history_truncated?,
          model_catalog,
          model
        )
        |> Map.merge(%{status: status, active: active, queue: queue, session_persisted?: true})
        |> schedule_recovery(wake_at)

      if active && status == :idle, do: send(self(), :start_active)
      {:ok, state}
    end
  end

  defp init_blocked(session, history, selection, resources_module, store, storage_opts, opts) do
    state =
      base_state(
        session.session_id,
        resources_module,
        nil,
        store,
        storage_opts,
        opts,
        selection,
        session,
        history.events,
        history.history_truncated?,
        [],
        nil
      )

    {:ok,
     %{
       state
       | status: :unavailable,
         session_persisted?: true,
         error: Event.json(Error.to_map({:resume_blocked, selection.blocked_reason}))
     }}
  end

  defp base_state(
         thread_id,
         resources_module,
         resources,
         store,
         storage_opts,
         opts,
         selection,
         session,
         history,
         history_truncated?,
         model_catalog,
         model
       ) do
    %{
      thread_id: thread_id,
      store: store,
      storage_opts: storage_opts,
      task_supervisor: Keyword.get(opts, :tasks, Jido.Console.Session.TaskSupervisor),
      bridge_module: Keyword.get(opts, :bridge_module, JidokaBridge),
      resources_module: resources_module,
      resources: resources,
      selection: selection,
      binding_state: Selection.state(selection),
      session_persisted?: false,
      pending_lock: nil,
      model_catalog: model_catalog,
      model: model,
      model_locked?: Selection.locked?(selection),
      options: opts,
      status: if(Selection.state(selection) == :resume_blocked, do: :unavailable, else: :idle),
      session: session,
      history: history,
      history_truncated?: history_truncated?,
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
  end

  defp new_session(%Selection{state: :ready_unlocked} = selection, thread_id, store) do
    with {:ok, session} <- Selection.start_session(selection, thread_id),
         {:ok, session} <- Store.put_session(store, session) do
      {:ok, session, true}
    end
  end

  defp new_session(%Selection{source: source}, thread_id, _store) when not is_nil(source) do
    with {:ok, session} <- Data.start(source.base_spec, session_id: thread_id) do
      {:ok, session, false}
    end
  end

  defp new_resources(_module, %Selection{state: :resume_blocked}, _thread_id, _opts),
    do: {:ok, nil}

  defp new_resources(module, %Selection{} = selection, thread_id, opts) do
    input =
      cond do
        selection.binding && module == ThreadResources -> selection.binding
        selection.binding -> selection.binding.bound_spec
        selection.source -> selection.source.base_spec
        true -> Jido.Console.Agents.Default
      end

    with {:ok, resources} <- module.new(thread_id, input, opts) do
      configure_legacy_resources(module, resources, selection)
    end
  end

  defp configure_legacy_resources(ThreadResources, resources, _selection), do: {:ok, resources}

  defp configure_legacy_resources(module, resources, %Selection{binding: binding})
       when not is_nil(binding) do
    configure_resources(module, resources, binding.model_id)
  end

  defp configure_legacy_resources(_module, resources, _selection), do: {:ok, resources}

  defp model_catalog(%Selection{} = selection, opts) do
    with {:ok, entries} <- Models.list(opts) do
      identity = selected_model_identity(selection)
      model = if identity, do: Enum.find(entries, &(&1.identity == identity))

      cond do
        selection.binding && is_nil(model) -> {:error, {:stored_model_unavailable, identity}}
        true -> {:ok, entries, model}
      end
    else
      {:error, %{__exception__: true} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.config_error("Unable to configure the session model", %{
           source: :model_catalog,
           reason: inspect(reason)
         })}
    end
  end

  defp selected_model_identity(%Selection{binding: binding}) when not is_nil(binding),
    do: binding.model_id

  defp selected_model_identity(%Selection{model_choice: %{id: id}}), do: id
  defp selected_model_identity(%Selection{}), do: nil

  defp recover_owner_queue(_selection, session, open, _store, _storage_opts, opts),
    do: recover_normally(session, open, opts)

  defp recover_normally(session, open, opts) do
    store = Keyword.get(opts, :store, Storage.session_store(Keyword.take(opts, [:writer, :deadline])))
    storage_opts = Keyword.take(opts, [:writer, :deadline])

    with {:ok, session, status, wake_at} <-
           Recovery.reconcile(session.session_id, session, open, store, storage_opts, now_ms(opts)) do
      {:ok, session, status, wake_at, nil, Queue.new(Keyword.get(opts, :queue_limit, 32))}
    end
  end

  defp submit(command, state) do
    digest = Command.digest(command)
    item = Command.item(command, digest)

    case Command.find_item(state, command.queue_item_id) do
      %{digest: ^digest} = existing ->
        {:reply, {:ok, Command.acceptance(existing, true, state)}, state}

      nil ->
        if state.active && Queue.full?(state.queue),
          do: retry_closed_or_full(command, digest, state),
          else: accept_new(command, item, state)

      _conflict ->
        {:reply, {:error, :command_conflict}, state}
    end
  end

  defp accept_new(_command, _item, %{binding_state: :needs_model} = state),
    do: {:reply, {:error, :binding_needs_model}, state}

  defp accept_new(_command, _item, %{binding_state: :needs_policy} = state),
    do: {:reply, {:error, :binding_needs_execution_policy}, state}

  defp accept_new(_command, _item, %{binding_state: :resume_blocked} = state),
    do: {:reply, {:error, {:resume_blocked, state.selection.blocked_reason}}, state}

  defp accept_new(command, item, %{binding_state: :ready_unlocked} = state),
    do: accept_first(command, item, state)

  defp accept_new(_command, item, %{binding_state: :locked} = state),
    do: accept_locked(item, state)

  defp accept_locked(item, state) do
    queued =
      Event.for_item(state, item, "prompt_queued", %{
        "input" => item.text,
        "context" => Event.json(item.context),
        "command_digest" => item.digest,
        "binding_digest" => state.selection.manifest["binding_digest"]
      })

    case append_event(state, queued) do
      {:ok, state, %{duplicate: true}} ->
        retry_closed(Command.from_item(item, state.thread_id), item.digest, lock_model(state))

      {:ok, state, %{duplicate: false}} when not is_nil(state.active) ->
        state = lock_model(state)

        case Queue.push(state.queue, item) do
          {:ok, queue} ->
            {:reply, {:ok, Command.acceptance(item, false, state)}, View.publish(%{state | queue: queue})}

          {:error, reason} ->
            {:reply, {:error, reason}, unavailable(state, reason)}
        end

      {:ok, state, %{duplicate: false}} ->
        state = View.publish(%{lock_model(state) | active: item, status: :idle})
        send(self(), :start_active)
        {:reply, {:ok, Command.acceptance(item, false, state)}, state}

      {:error, {:event_conflict, _id}, state} ->
        retry_closed(Command.from_item(item, state.thread_id), item.digest, state)

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp accept_first(command, item, state) do
    draft_manifest = state.selection.manifest
    operation_id = Command.lock_operation_id(command)
    command_digest = Command.first_lock_digest(command, draft_manifest["binding_digest"])

    with {:ok, locked_selection} <- Selection.lock(state.selection, operation_id, command_digest),
         locked_session = %{state.session | revision: state.session.revision + 1},
         {:ok, locked_session} <- BindingManifest.put(locked_session, locked_selection.manifest),
         event =
           Event.for_item(
             state,
             item,
             "prompt_queued",
             %{
               "input" => item.text,
               "context" => Event.json(item.context),
               "command_digest" => item.digest,
               "binding_digest" => locked_selection.manifest["binding_digest"],
               "lock_operation_id" => operation_id,
               "first_prompt_command_digest" => command_digest
             },
             locked_session.revision
           ) do
      case Storage.lock_first_prompt(
             locked_session,
             event,
             operation_id,
             state.session.revision,
             state.selection.generation,
             state.storage_opts
           ) do
        {:ok, %{session: session, event: stored, duplicate: duplicate}} ->
          state =
            state
            |> install_locked_selection(locked_selection, session)
            |> add_history(stored)
            |> Map.merge(%{active: item, status: :idle})
            |> View.publish()

          send(self(), :start_active)
          {:reply, {:ok, Command.acceptance(item, duplicate, state)}, state}

        {:error, {kind, ^operation_id} = reason} when kind in [:timeout_unknown, :write_unknown] ->
          pending = %{
            operation_id: operation_id,
            command: command,
            item: item,
            event: event,
            selection: locked_selection,
            session: locked_session
          }

          state =
            state
            |> Map.merge(%{pending_lock: pending, status: :reconciling, error: Event.json(Error.to_map(reason))})
            |> View.publish()

          {:reply, {:error, reason}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp install_locked_selection(state, selection, session) do
    %{
      state
      | selection: selection,
        binding_state: :locked,
        session: session,
        session_persisted?: true,
        model_locked?: true,
        pending_lock: nil,
        error: nil
    }
  end

  defp add_history(state, %Event{} = stored) do
    history = Enum.take((state.history ++ [stored]) |> Enum.reverse(), 200) |> Enum.reverse()

    %{
      state
      | history: history,
        history_truncated?: state.history_truncated? or length(state.history) + 1 > 200
    }
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

  defp select_model(_command, %{binding_state: :locked} = state) do
    error =
      Error.validation_error("Model selection is locked after the first prompt is accepted", %{
        source: :session_model
      })

    {:reply, {:error, error}, state}
  end

  defp select_model(%Command{text: identity}, state) do
    case Selection.select_model(state.selection, identity, :tui) do
      {:ok, selection} -> persist_selection(state, selection, :model)
      {:error, reason} -> {:reply, {:error, model_selection_error(identity, reason)}, state}
    end
  end

  defp select_agent(%Command{}, %{binding_state: :locked} = state),
    do: {:reply, {:error, :binding_locked}, state}

  defp select_agent(%Command{text: source}, state) do
    case Selection.select_agent(state.selection, source) do
      {:ok, selection} -> persist_selection(state, selection)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp select_execution_policy(
         %Command{},
         %{binding_state: :locked} = state
       ),
       do: {:reply, {:error, :binding_locked}, state}

  defp select_execution_policy(%Command{text: id, payload: payload}, state) do
    root = Map.get(payload, "project_root", Map.get(payload, :project_root))

    case Selection.select_execution_policy(state.selection, id, root, :tui) do
      {:ok, selection} -> persist_selection(state, selection)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_selection(state, selection, reply_kind \\ :binding)

  defp persist_selection(state, %Selection{state: :ready_unlocked} = selection, reply_kind) do
    expected_revision = state.session.revision
    expected_generation = persisted_generation(state)

    with {:ok, session, persisted?} <- persist_ready_selection(state, selection),
         {:ok, resources} <- new_resources(state.resources_module, selection, state.thread_id, state.options),
         {:ok, model_catalog, model} <- model_catalog(selection, state.options) do
      close_replaced_resources(state)

      state =
        View.publish(%{
          state
          | selection: selection,
            binding_state: :ready_unlocked,
            session: session,
            session_persisted?: persisted?,
            resources: resources,
            model_catalog: model_catalog,
            model: model,
            error: nil
        })

      reply =
        case reply_kind do
          :model ->
            model_projection(model, false)

          :binding ->
            %{
              "binding_state" => "ready_unlocked",
              "binding" => Selection.safe_projection(selection),
              "previous_revision" => expected_revision,
              "previous_generation" => expected_generation
            }
        end

      {:reply, {:ok, reply}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_selection(state, %Selection{} = selection, _reply_kind) do
    state =
      View.publish(%{
        state
        | selection: selection,
          binding_state: Selection.state(selection),
          error: nil
      })

    {:reply,
     {:ok,
      %{
        "binding_state" => Atom.to_string(Selection.state(selection)),
        "binding" => Selection.safe_projection(selection)
      }}, state}
  end

  defp persist_ready_selection(%{session_persisted?: false} = state, selection) do
    with {:ok, session} <- Selection.start_session(selection, state.thread_id),
         {:ok, session} <- Store.put_session(state.store, session) do
      {:ok, session, true}
    end
  end

  defp persist_ready_selection(state, selection) do
    expected_generation = persisted_generation(state)

    with {:ok, session} <- Selection.put_draft(selection, state.session),
         {:ok, session} <-
           Storage.put_binding_draft(
             session,
             state.session.revision,
             expected_generation,
             state.storage_opts
           ) do
      {:ok, session, true}
    end
  end

  defp persisted_generation(%{session: %Data{} = session}) do
    case BindingManifest.fetch(session) do
      {:ok, manifest} -> manifest["draft_generation"]
      {:error, _reason} -> 0
    end
  end

  defp close_replaced_resources(%{resources: nil}), do: :ok

  defp close_replaced_resources(state) do
    state.resources_module.close(state.resources)
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
          "error" => Event.json(Error.to_map(reason))
        })
    end
  end

  defp finish_result(state, {:ok, %Data{} = session, result}),
    do:
      finish_terminal(%{state | session: session}, "prompt_succeeded", %{"result" => Event.json(Jidoka.project(result))})

  defp finish_result(state, {:cancelled, cancellation}),
    do: finish_loaded(state, "prompt_cancelled", %{"error" => Event.json(Error.to_map(cancellation))})

  defp finish_result(state, {:error, reason}),
    do: finish_loaded(state, "prompt_failed", %{"error" => Event.json(Error.to_map(reason))})

  defp finish_result(state, result),
    do: finish_loaded(state, "prompt_failed", %{"error" => Event.json(Error.to_map({:invalid_result, result}))})

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
    do: finish_terminal(state, "prompt_failed", %{"error" => Event.json(Error.to_map(reason))})

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

  defp model_selection_error(identity, reason) do
    Error.validation_error("Unavailable model #{identity}", %{
      identity: identity,
      reason: inspect(reason),
      selectable_tiers: [:supported, :beta]
    })
  end

  defp model_projection(entry, locked?) do
    %{"identity" => entry.identity, "tier" => Atom.to_string(entry.tier), "locked" => locked?}
  end

  defp model_configuration_reason?(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.contains?("model")

  defp model_configuration_reason?(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    reason |> elem(0) |> model_configuration_reason?()
  end

  defp model_configuration_reason?(_reason), do: false

  defp configure_resources(module, resources, identity) do
    if function_exported?(module, :configure_model, 2) do
      module.configure_model(resources, identity)
    else
      {:error,
       Error.config_error("Session resources cannot configure a model", %{
         module: inspect(module),
         source: :session_model
       })}
    end
  end

  defp require_locked_binding(%{binding_state: :locked}), do: :ok

  defp require_locked_binding(%{binding_state: state}) when state in [:needs_model, :needs_policy],
    do: {:error, {:binding_not_ready, state}}

  defp require_locked_binding(%{binding_state: :resume_blocked}), do: {:error, :resume_blocked}
  defp require_locked_binding(%{binding_state: :ready_unlocked}), do: {:error, :binding_not_locked}
  defp require_locked_binding(_legacy_state), do: :ok

  defp persist_runtime_session(
         %{selection: %Selection{state: :locked, manifest: manifest}} = state,
         resources,
         session
       ) do
    runtime_fingerprint =
      if function_exported?(state.resources_module, :runtime_definition_fingerprint, 1),
        do: state.resources_module.runtime_definition_fingerprint(resources),
        else: manifest["runtime_definition_fingerprint"]

    Storage.install_runtime_spec(
      session,
      manifest["binding_digest"],
      runtime_fingerprint,
      state.storage_opts
    )
  end

  defp persist_runtime_session(state, _resources, session), do: Store.put_session(state.store, session)

  defp lock_model(%{model_locked?: true} = state), do: state
  defp lock_model(state), do: %{state | model_locked?: true}

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

  defp uncertain_write?({:timeout_unknown, _id}), do: true
  defp uncertain_write?({:write_unknown, _id}), do: true
  defp uncertain_write?(_reason), do: false

  defp start_bridge_task(supervisor, fun) do
    Task.Supervisor.start_child(supervisor, fun)
  catch
    :exit, _reason -> {:error, :bridge_supervisor_unavailable}
  end

  defp now_ms(opts), do: if(is_function(opts[:clock], 0), do: opts[:clock].(), else: System.system_time(:millisecond))
end
