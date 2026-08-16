defmodule Jido.Console.Session.Server do
  @moduledoc """
  Process owner for one live semantic session and its runtime requests.

  Raw runtime sessions and request handles stay in this process. Model and
  tool waits run under the session task supervisor. Clients can attach and
  detach without changing runtime ownership or stopping active work.
  """

  use GenServer, restart: :temporary

  alias Jido.Console.Runtime.Result, as: RuntimeResult
  alias Jido.Console.Runtime.Result.{Error, Ok, PendingReview}

  alias Jido.Console.Session.{
    Delivery,
    DynamicSupervisor,
    Event,
    Identity,
    Identity.Admission,
    Input,
    Projection,
    Recovery,
    Reducer,
    Registry,
    Request,
    State
  }

  @completed_limit 100

  @type name :: GenServer.name() | pid()

  @doc "Temporary child spec for one live session."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {:session, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc "Starts a session server registered by session ID."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    registry = Keyword.get(opts, :registry, Registry)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(session_id, registry))
  end

  @doc "Starts or returns the live server for one session ID."
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id, opts \\ []) when is_binary(session_id) do
    registry = Keyword.get(opts, :registry, Registry)

    case Registry.lookup(session_id, registry) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        case DynamicSupervisor.start_session(__MODULE__, Keyword.put(opts, :session_id, session_id)) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc "Attaches a client to the session and returns its current snapshot."
  @spec attach(name(), Identity.t()) :: {:ok, map()} | {:error, term()}
  def attach(server, client), do: GenServer.call(server, {:attach, client, self()})

  @doc "Detaches a client without stopping session work."
  @spec detach(name(), Identity.t()) :: :ok | {:error, term()}
  def detach(server, client), do: GenServer.call(server, {:detach, client})

  @doc "Queues a detach without waiting for runtime startup work."
  @spec detach_async(name(), Identity.t()) :: :ok
  def detach_async(server, client), do: GenServer.cast(server, {:detach, client})

  @doc "Returns the current semantic state."
  @spec state(name()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @doc "Configures a runtime that will be owned by this session."
  @spec configure_runtime(name(), String.t(), module(), term(), keyword()) :: :ok | {:error, term()}
  def configure_runtime(server, client_id, runtime, agent, opts) do
    GenServer.call(server, {:configure_runtime, client_id, runtime, agent, opts}, :infinity)
  end

  @doc "Returns bounded runtime information for one attached client."
  @spec runtime_info(name(), String.t()) :: {:ok, map()} | {:error, term()}
  def runtime_info(server, client_id), do: GenServer.call(server, {:runtime_info, client_id})

  @doc "Starts one configured runtime turn."
  @spec start_turn(name(), String.t(), String.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def start_turn(server, client_id, prompt, opts) do
    GenServer.call(server, {:start_turn, client_id, prompt, opts}, :infinity)
  end

  @doc "Starts caller-defined work while retaining its raw handle in the session owner."
  @spec start_operation(name(), String.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def start_operation(server, client_id, spec) do
    GenServer.call(server, {:start_operation, client_id, spec}, :infinity)
  end

  @doc "Waits for one session-owned request."
  @spec await_request(name(), Request.t(), timeout()) :: term()
  def await_request(server, request, timeout) do
    GenServer.call(server, {:await_request, request}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :session_await_timeout}
  end

  @doc "Requests cancellation without exposing the raw runtime handle."
  @spec cancel_request(name(), String.t(), Request.t(), keyword()) ::
          {:ok, :requested} | {:error, term()}
  def cancel_request(server, client_id, request, opts) do
    GenServer.call(server, {:cancel_request, client_id, request, opts})
  end

  @doc "Requests cancellation and waits for the runtime cancellation result."
  @spec cancel_request_wait(name(), String.t(), Request.t(), keyword(), timeout()) :: term()
  def cancel_request_wait(server, client_id, request, opts, timeout \\ :infinity) do
    GenServer.call(server, {:cancel_request_wait, client_id, request, opts}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :session_cancel_timeout}
  end

  @doc "Responds to a pending runtime review through the session owner."
  @spec respond_review(name(), String.t(), :approve | :deny, Request.t(), term(), keyword()) ::
          {:ok, :requested} | {:error, term()}
  def respond_review(server, client_id, decision, request, review, opts) do
    GenServer.call(server, {:respond_review, client_id, decision, request, review, opts})
  end

  @doc "Admits a classified event through the reducer."
  @spec admit_event(name(), map()) :: {:ok, State.t()} | {:error, term()}
  def admit_event(server, event), do: GenServer.call(server, {:admit_event, event})

  @doc "Allocates the next Console sequence for an owner-built event."
  @spec next_sequence(name()) :: non_neg_integer()
  def next_sequence(server), do: GenServer.call(server, :next_sequence)

  @doc "Admits an identity-bound worker result."
  @spec admit_result(name(), Identity.t(), term()) :: {:ok, term()} | {:error, term()}
  def admit_result(server, identity, result) do
    GenServer.call(server, {:admit_result, identity, result})
  end

  @doc "Admits process-lifetime input for this session."
  @spec admit_input(name(), Input.t()) :: {:ok, Input.t()} | {:error, term()}
  def admit_input(server, input), do: GenServer.call(server, {:admit_input, input})

  @doc "Acknowledges a delivered sequence for one attached client."
  @spec ack(name(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, Delivery.t()} | {:error, term()}
  def ack(server, client_id, session_id, sequence) do
    GenServer.call(server, {:ack, client_id, session_id, sequence})
  end

  @doc "Recovers one attached client from a delivery gap."
  @spec recover(name(), String.t()) :: {:ok, Delivery.t(), State.t()} | {:error, term()}
  def recover(server, client_id) do
    GenServer.call(server, {:recover, client_id})
  end

  @doc "Stops one live session server."
  @spec stop(name()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 5_000)
  catch
    :exit, {:noproc, _info} -> :ok
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    session = Identity.new!(:session, id: session_id)

    {:ok,
     %{
       session: session,
       state: State.new(session),
       clients: %{},
       admissions: %{},
       results: [],
       inputs: [],
       reserved: 0,
       runtime: nil,
       active: nil,
       completed: %{},
       completed_order: [],
       tasks: %{},
       task_supervisor: Keyword.get(opts, :tasks, Jido.Console.Session.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:attach, client, pid}, _from, state) do
    if client.session_id != state.session.id do
      {:reply, {:error, :cross_session_result}, state}
    else
      {previous, clients} = Map.pop(state.clients, client.id)
      if previous, do: Process.demonitor(previous.ref, [:flush])

      record = %{
        identity: client,
        pid: pid,
        ref: Process.monitor(pid),
        delivery: Delivery.new(client_id: client.id, session_id: state.session.id)
      }

      clients = Map.put(clients, client.id, record)
      {:reply, {:ok, Reducer.snapshot(state.state)}, %{state | clients: clients}}
    end
  end

  def handle_call({:detach, client}, _from, state) do
    case Map.pop(state.clients, client.id) do
      {nil, _clients} ->
        {:reply, {:error, :not_attached}, state}

      {%{ref: ref}, clients} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | clients: clients}}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state.state, state}

  def handle_call({:runtime_info, client_id}, _from, state) do
    if attached?(state, client_id) do
      info =
        case state.runtime do
          nil ->
            %{configured?: false, active_request: active_public_request(state)}

          runtime ->
            %{
              configured?: true,
              active_request: active_public_request(state),
              client_setup: runtime.client_setup
            }
        end

      {:reply, {:ok, info}, state}
    else
      {:reply, {:error, :not_attached}, state}
    end
  end

  def handle_call({:configure_runtime, client_id, runtime, agent, opts}, _from, state) do
    cond do
      not attached?(state, client_id) ->
        {:reply, {:error, :not_attached}, state}

      state.active != nil ->
        {:reply, {:error, :session_busy}, state}

      not is_atom(runtime) ->
        {:reply, {:error, :invalid_runtime}, state}

      true ->
        case open_runtime(runtime, agent, opts) do
          {:ok, configured} ->
            close_runtime(state.runtime)
            {:reply, :ok, %{state | runtime: configured}}

          {:error, reason} ->
            close_owned_resource(opts)
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:start_turn, client_id, prompt, opts}, _from, state) do
    with :ok <- require_attached(state, client_id),
         :ok <- require_idle(state),
         {:ok, spec} <- runtime_operation(state.runtime, prompt, opts),
         {:ok, request, state} <- begin_operation(state, spec) do
      {:reply, {:ok, request}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_operation, client_id, spec}, _from, state) do
    with :ok <- require_attached(state, client_id),
         :ok <- require_idle(state),
         {:ok, normalized} <- normalize_operation(spec),
         {:ok, request, state} <- begin_operation(state, normalized) do
      {:reply, {:ok, request}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await_request, %Request{} = request}, from, state) do
    cond do
      request.session_id != state.session.id ->
        {:reply, {:error, :cross_session_result}, state}

      Map.has_key?(state.completed, request.id) ->
        {:reply, Map.fetch!(state.completed, request.id), state}

      state.active && state.active.request.id == request.id ->
        active = Map.update!(state.active, :waiters, &(&1 ++ [from]))
        {:noreply, %{state | active: active}}

      true ->
        {:reply, {:error, :stale_request}, state}
    end
  end

  def handle_call({:cancel_request, client_id, %Request{} = request, opts}, _from, state) do
    start_cancel(state, client_id, request, opts, nil)
  end

  def handle_call({:cancel_request_wait, client_id, %Request{} = request, opts}, from, state) do
    start_cancel(state, client_id, request, opts, from)
  end

  def handle_call(
        {:respond_review, client_id, decision, %Request{} = request, review, opts},
        _from,
        state
      ) do
    with :ok <- require_attached(state, client_id),
         true <- decision in [:approve, :deny],
         {:ok, active} <- matching_active(state, request),
         pending when not is_nil(pending) <- active.pending_result,
         respond when is_function(respond, 5) <- active.respond_review do
      owner = self()

      task =
        start_task(state, fn ->
          safe_call(fn -> respond.(decision, pending, review, opts, owner) end)
        end)

      tasks = put_task(state.tasks, task, {:review, request.id})
      active = %{active | pending_result: nil}
      {:reply, {:ok, :requested}, %{state | active: active, tasks: tasks}}
    else
      false -> {:reply, {:error, :invalid_review_decision}, state}
      nil -> {:reply, {:error, :review_not_pending}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:next_sequence, _from, state) do
    next = max(state.reserved, state.state.sequence) + 1
    {:reply, next, %{state | reserved: next}}
  end

  def handle_call({:admit_event, event}, _from, state) do
    case admit_event_state(state, event) do
      {:ok, state} -> {:reply, {:ok, state.state}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:admit_input, input}, _from, state) do
    if input.identity.session_id != state.session.id do
      {:reply, {:error, :cross_session_result}, state}
    else
      {:reply, {:ok, input}, %{state | inputs: bounded_append(state.inputs, input)}}
    end
  end

  def handle_call({:ack, client_id, session_id, sequence}, _from, state) do
    case Map.fetch(state.clients, client_id) do
      :error ->
        {:reply, {:error, :not_attached}, state}

      {:ok, client} ->
        case Delivery.ack(client.delivery, client_id, session_id, sequence) do
          {:ok, delivery} ->
            clients = Map.put(state.clients, client_id, %{client | delivery: delivery})
            {:reply, {:ok, delivery}, %{state | clients: clients}}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:recover, client_id}, _from, state) do
    case Map.fetch(state.clients, client_id) do
      :error ->
        {:reply, {:error, :not_attached}, state}

      {:ok, client} ->
        case Recovery.recover(state.state, client.delivery) do
          {:ok, delivery, recovered} ->
            clients = Map.put(state.clients, client_id, %{client | delivery: delivery})
            {:reply, {:ok, delivery, recovered}, %{state | clients: clients}}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:admit_result, identity, result}, _from, state) do
    if identity.session_id != state.session.id do
      {:reply, {:error, :cross_session_result}, state}
    else
      admission = Map.get_lazy(state.admissions, identity.id, fn -> Admission.new(identity) end)

      case Admission.admit(admission, identity) do
        {:ok, admission} ->
          {:reply, {:ok, result},
           %{
             state
             | admissions: Map.put(state.admissions, identity.id, admission),
               results: bounded_append(state.results, result)
           }}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_cast({:detach, client}, state) do
    case Map.pop(state.clients, client.id) do
      {nil, _clients} ->
        {:noreply, state}

      {%{ref: ref}, clients} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | clients: clients}}
    end
  end

  @impl true
  def handle_info({:jidoka_turn_event, event}, %{active: active} = state) when not is_nil(active) do
    state = project_runtime_event(state, event)
    broadcast_runtime(state.clients, {:session_runtime_event, state.session.id, active.request, event})
    {:noreply, state}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) and is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {{kind, _pid}, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}
    {:noreply, complete_task(state, kind, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.tasks, ref) do
    {{kind, _pid}, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}
    {:noreply, complete_task(state, kind, {:error, {:runtime_task_failed, reason}})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    clients =
      state.clients
      |> Enum.reject(fn {_id, client} -> client.ref == ref end)
      |> Map.new()

    {:noreply, %{state | clients: clients}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.tasks
    |> Map.values()
    |> Enum.each(fn {_kind, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    close_runtime(state.runtime)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp open_runtime(runtime, agent, opts) do
    resource = Keyword.get(opts, :owned_resource)
    closer = Keyword.get(opts, :resource_closer)
    client_setup = Keyword.get(opts, :client_setup)
    runtime_opts = Keyword.drop(opts, [:owned_resource, :resource_closer, :client_setup])

    case safe_call(fn -> runtime.start_session(agent, runtime_opts) end) do
      {:ok, {:ok, session}} ->
        {:ok,
         %{
           module: runtime,
           session: session,
           resource: resource,
           resource_closer: closer,
           client_setup: client_setup
         }}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_runtime_start, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_cancel(state, client_id, request, opts, waiter) do
    with :ok <- require_attached(state, client_id),
         {:ok, active} <- matching_active(state, request),
         cancel when is_function(cancel, 2) <- active.cancel do
      task = start_task(state, fn -> safe_call(fn -> cancel.(active.raw_request, opts) end) end)
      tasks = put_task(state.tasks, task, {:cancel, request.id, List.wrap(waiter)})
      state = admit_control(state, "control_requested", request, "cancel")

      if waiter do
        {:noreply, %{state | tasks: tasks}}
      else
        {:reply, {:ok, :requested}, %{state | tasks: tasks}}
      end
    else
      nil -> {:reply, {:error, :cancel_unsupported}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp runtime_operation(nil, _prompt, _opts), do: {:error, :runtime_not_configured}

  defp runtime_operation(runtime, prompt, opts) do
    await_opts = Keyword.get(opts, :await_opts, timeout: 30_000, cancel_on_timeout: false)
    turn_opts = Keyword.get(opts, :turn_opts, [])
    module = runtime.module
    session = runtime.session

    {:ok,
     %{
       start: fn owner -> module.start_turn(session, prompt, owner, turn_opts) end,
       await: fn request -> module.await(request, await_opts) end,
       cancel: fn request, cancel_opts -> module.cancel(request, cancel_opts) end,
       respond_review: fn decision, result, review, review_opts, owner ->
         callback = if decision == :approve, do: :approve, else: :deny
         review_opts = review_opts |> Keyword.put(:stream, true) |> Keyword.put(:stream_to, owner)

         if function_exported?(module, callback, 3) do
           apply(module, callback, [result, review, review_opts])
         else
           {:error, {:runtime_review_response_unsupported, decision}}
         end
       end,
       runtime?: true,
       prompt: prompt
     }}
  end

  defp normalize_operation(spec) when is_list(spec) do
    start = Keyword.get(spec, :start)
    await = Keyword.get(spec, :await)

    if is_function(start, 1) and is_function(await, 1) do
      {:ok,
       %{
         start: start,
         await: await,
         cancel: Keyword.get(spec, :cancel),
         respond_review: Keyword.get(spec, :respond_review),
         request_id: Keyword.get(spec, :request_id),
         run_id: Keyword.get(spec, :run_id),
         runtime?: false,
         prompt: Keyword.get(spec, :prompt)
       }}
    else
      {:error, :invalid_session_operation}
    end
  end

  defp normalize_operation(_spec), do: {:error, :invalid_session_operation}

  defp begin_operation(state, spec) do
    case safe_call(fn -> spec.start.(self()) end) do
      {:ok, {:ok, raw_request}} ->
        request = public_request(state, raw_request, spec)

        active = %{
          request: request,
          raw_request: raw_request,
          await: spec.await,
          cancel: spec.cancel,
          respond_review: spec.respond_review,
          runtime?: spec.runtime?,
          waiters: [],
          pending_result: nil,
          seen: MapSet.new(),
          last_jidoka_seq: %{}
        }

        state = %{state | active: active}

        started_payload =
          %{"status" => "running"}
          |> maybe_put("prompt", Map.get(spec, :prompt))

        state = admit_owner_event(state, "run_started", request, started_payload)
        broadcast_runtime(state.clients, {:session_runtime_started, state.session.id, request})
        task = start_task(state, fn -> safe_call(fn -> spec.await.(raw_request) end) end)
        tasks = put_task(state.tasks, task, {:await, request.id})
        {:ok, request, %{state | tasks: tasks}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_runtime_request, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp public_request(state, raw_request, spec) do
    request_id = Map.get(spec, :request_id) || raw_request_id(raw_request) || Identity.new!(:request).id
    run_id = Map.get(spec, :run_id) || Identity.new!(:run, session_id: state.session.id).id

    %Request{
      id: Identity.new!(:request, session_id: state.session.id).id,
      request_id: request_id,
      run_id: run_id,
      session_id: state.session.id
    }
  end

  defp raw_request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id

  defp raw_request_id(%{sequence: %{request_id: request_id}}) when is_binary(request_id),
    do: request_id

  defp raw_request_id(_request), do: nil

  defp start_task(state, fun) do
    case GenServer.whereis(state.task_supervisor) do
      nil ->
        task = Task.async(fun)
        Process.unlink(task.pid)
        task

      _pid ->
        Task.Supervisor.async_nolink(state.task_supervisor, fun)
    end
  end

  defp put_task(tasks, %Task{ref: ref, pid: pid}, kind), do: Map.put(tasks, ref, {kind, pid})

  defp complete_task(state, {:await, request_id}, outcome) do
    if active_request?(state, request_id),
      do: complete_runtime_result(state, unwrap_task(outcome)),
      else: state
  end

  defp complete_task(state, {:review, request_id}, outcome) do
    if active_request?(state, request_id),
      do: complete_runtime_result(state, unwrap_task(outcome)),
      else: state
  end

  defp complete_task(state, {:cancel, request_id, waiters}, outcome) do
    result = unwrap_task(outcome)
    Enum.each(waiters, &GenServer.reply(&1, result))

    if active_request?(state, request_id) do
      active = state.active

      state =
        state
        |> admit_control("control_completed", active.request, "cancel")
        |> broadcast_control_result(result)

      case {state.active.runtime?, result} do
        {true, {:ok, %Jidoka.Cancellation{} = cancellation}} ->
          cancelled =
            RuntimeResult.cancelled(
              active.request.request_id,
              state.runtime.session,
              active.raw_request,
              cancellation,
              raw: {:cancelled, cancellation}
            )

          state
          |> stop_await_task(request_id)
          |> complete_runtime_result(cancelled)

        _other ->
          state
      end
    else
      state
    end
  end

  defp unwrap_task({:ok, result}), do: result
  defp unwrap_task({:error, _reason} = error), do: error
  defp unwrap_task(result), do: result

  defp complete_runtime_result(state, result) do
    active = state.active
    state = update_runtime_session(state, result)
    pending? = pending_result?(result)

    state =
      if pending?,
        do: state,
        else: admit_owner_event(state, terminal_type(result), active.request, result_payload(result))

    broadcast_runtime(state.clients, {:session_runtime_result, state.session.id, active.request, result})
    Enum.each(active.waiters, &GenServer.reply(&1, result))

    if pending? do
      %{state | active: %{active | pending_result: result, waiters: []}}
    else
      put_completed(%{state | active: nil}, active.request.id, result)
    end
  end

  defp update_runtime_session(%{runtime: nil} = state, _result), do: state

  defp update_runtime_session(state, result) do
    case result_session(result) do
      nil -> state
      session -> put_in(state.runtime.session, session)
    end
  end

  defp result_session(%RuntimeResult{session: session}), do: session
  defp result_session(_result), do: nil

  defp pending_result?(%RuntimeResult{outcome: %PendingReview{}}), do: true
  defp pending_result?(_result), do: false

  defp terminal_type(%RuntimeResult{outcome: %Error{}}), do: "run_failed"
  defp terminal_type({:error, _reason}), do: "run_failed"
  defp terminal_type(_result), do: "run_completed"

  defp result_payload(%RuntimeResult{outcome: %Ok{content: content}} = result) do
    %{
      "status" => Atom.to_string(RuntimeResult.status(result)),
      "content" => bounded_text(content),
      "error" => nil
    }
  end

  defp result_payload(%RuntimeResult{outcome: %Error{reason: reason}}) do
    %{"status" => "error", "content" => nil, "error" => portable_reason(reason)}
  end

  defp result_payload(%RuntimeResult{} = result) do
    %{"status" => Atom.to_string(RuntimeResult.status(result)), "content" => nil, "error" => nil}
  end

  defp result_payload({:error, reason}), do: %{"status" => "error", "error" => portable_reason(reason)}
  defp result_payload(_result), do: %{"status" => "completed"}

  defp stop_await_task(state, request_id) do
    case Enum.find(state.tasks, fn {_ref, {kind, _pid}} -> kind == {:await, request_id} end) do
      {ref, {_kind, pid}} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        %{state | tasks: Map.delete(state.tasks, ref)}

      nil ->
        state
    end
  end

  defp project_runtime_event(state, event) do
    active = state.active

    opts = [
      sequence: state.state.sequence + 1,
      session: state.session,
      seen: active.seen,
      last_jidoka_seq: Map.get(active.last_jidoka_seq, runtime_request_id(event))
    ]

    case Projection.project(event, opts) do
      {:ok, projected} ->
        if projected["payload"]["terminal"] == true do
          track_projection(state, projected)
        else
          case admit_event_state(state, projected) do
            {:ok, state} ->
              track_projection(state, projected)

            {:error, reason, state} ->
              broadcast_runtime(state.clients, {:session_runtime_error, state.session.id, active.request, reason})
              state
          end
        end

      {:ignore, :duplicate} ->
        state

      {:error, reason} ->
        broadcast_runtime(state.clients, {:session_runtime_error, state.session.id, active.request, reason})
        state
    end
  end

  defp track_projection(state, projected) do
    payload = projected["payload"]
    key = {payload["request_id"], payload["jidoka_sequence"]}

    active = %{
      state.active
      | seen: MapSet.put(state.active.seen, key),
        last_jidoka_seq:
          Map.put(
            state.active.last_jidoka_seq,
            payload["request_id"],
            payload["jidoka_sequence"]
          )
    }

    %{state | active: active}
  end

  defp admit_owner_event(state, type, request, extra) do
    sequence = state.state.sequence + 1

    attrs =
      %{
        type: type,
        id: "plt_#{request.id}_#{sequence}",
        session_id: state.session.id,
        sequence: sequence,
        durability: "process",
        sensitivity: "public",
        origin: %{kind: "session", actor_id: state.session.id},
        trust: %{evidence: "session-owner", policy: "session-owner"},
        identities: [
          Identity.to_protocol(state.session),
          %{"kind" => "request", "id" => request.id, "session_id" => state.session.id}
        ],
        request_id: request.request_id,
        run_id: request.run_id
      }
      |> Map.merge(extra)

    with {:ok, event} <- Event.classify(attrs),
         {:ok, state} <- admit_event_state(state, event) do
      state
    else
      _error -> state
    end
  end

  defp admit_control(state, type, request, control),
    do: admit_owner_event(state, type, request, %{"control" => control})

  defp admit_event_state(state, event) do
    case Reducer.apply_event(state.state, event) do
      {:ok, semantic} ->
        clients = publish(state.clients, semantic)
        {:ok, %{state | state: semantic, clients: clients, reserved: max(state.reserved, semantic.sequence)}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp broadcast_control_result(state, result) do
    broadcast_runtime(state.clients, {:session_control_result, state.session.id, state.active.request, result})
    state
  end

  defp put_completed(state, request_id, result) do
    order = state.completed_order ++ [request_id]
    completed = Map.put(state.completed, request_id, result)

    if length(order) > @completed_limit do
      [oldest | order] = order
      %{state | completed: Map.delete(completed, oldest), completed_order: order}
    else
      %{state | completed: completed, completed_order: order}
    end
  end

  defp matching_active(state, %Request{} = request) do
    cond do
      request.session_id != state.session.id -> {:error, :cross_session_result}
      state.active == nil -> {:error, :request_already_finished}
      state.active.request.id != request.id -> {:error, :stale_request}
      true -> {:ok, state.active}
    end
  end

  defp active_request?(state, request_id), do: state.active && state.active.request.id == request_id
  defp active_public_request(%{active: nil}), do: nil
  defp active_public_request(%{active: active}), do: active.request
  defp attached?(state, client_id), do: Map.has_key?(state.clients, client_id)
  defp require_attached(state, client_id), do: if(attached?(state, client_id), do: :ok, else: {:error, :not_attached})
  defp require_idle(%{active: nil}), do: :ok
  defp require_idle(_state), do: {:error, :session_busy}

  defp publish(clients, session_state) do
    update = session_state |> Reducer.snapshot() |> Map.put("coalesce", true)

    Map.new(clients, fn {id, client} ->
      {id, deliver(client, session_state.session_id, update)}
    end)
  end

  defp deliver(client, session_id, update) do
    case Delivery.offer(client.delivery, update) do
      {:ok, delivery, payload} ->
        send(client.pid, {:session_updated, session_id, payload})
        %{client | delivery: delivery}

      {:gap, delivery, nil} ->
        %{client | delivery: delivery}

      {:gap, delivery, gap} ->
        send(client.pid, {:session_gap, session_id, gap})
        %{client | delivery: delivery}
    end
  end

  defp broadcast_runtime(clients, message),
    do: Enum.each(clients, fn {_id, client} -> send(client.pid, message) end)

  defp close_runtime(nil), do: :ok

  defp close_runtime(runtime) do
    module = runtime.module

    if function_exported?(module, :close_session, 1) do
      _result = safe_call(fn -> module.close_session(runtime.session) end)
    end

    close_resource(runtime.resource, runtime.resource_closer)
    :ok
  end

  defp close_owned_resource(opts),
    do: close_resource(Keyword.get(opts, :owned_resource), Keyword.get(opts, :resource_closer))

  defp close_resource(nil, _closer), do: :ok

  defp close_resource(resource, {module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    _result = safe_call(fn -> apply(module, function, [resource | args]) end)
    :ok
  end

  defp close_resource(_resource, _closer), do: :ok

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp bounded_append(items, item), do: Enum.take(items ++ [item], -@completed_limit)
  defp runtime_request_id(%{request_id: request_id}), do: request_id
  defp runtime_request_id(_event), do: nil
  defp bounded_text(nil), do: nil
  defp bounded_text(text) when is_binary(text), do: String.slice(text, 0, 200_000)
  defp bounded_text(value), do: value |> inspect(limit: 20) |> String.slice(0, 4_096)
  defp portable_reason(nil), do: nil
  defp portable_reason(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 4_096)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
