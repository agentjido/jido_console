defmodule Jido.Console.Session.Server do
  @moduledoc """
  Process owner for one live semantic session and its runtime requests.

  Raw runtime sessions and request handles stay in this process. Model and
  tool waits run under the session task supervisor. Clients can attach and
  detach without changing runtime ownership or stopping active work.
  """

  use GenServer, restart: :temporary

  alias Jido.Console.Runtime.Result, as: RuntimeResult
  alias Jido.Console.Runtime.Result.{Cancelled, Error, Ok, PendingReview}

  alias Jido.Console.Session.{
    Admission,
    Delivery,
    DynamicSupervisor,
    Effect,
    Event,
    Generation,
    History,
    Identity,
    Projection,
    Queue,
    Recovery,
    Reducer,
    Registry,
    Request,
    State
  }

  alias Jido.Console.Session.Identity.Admission, as: IdentityAdmission

  @completed_limit 100
  @terminal_event_wait_ms 50

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
    ensure_started(session_id, opts, 10)
  end

  defp ensure_started(session_id, opts, attempts) do
    registry = Keyword.get(opts, :registry, Registry)

    case Registry.lookup(session_id, registry) do
      {:ok, pid} ->
        if Process.alive?(pid),
          do: {:ok, pid},
          else: retry_start(session_id, opts, attempts)

      _missing_or_stopping ->
        case DynamicSupervisor.start_session(__MODULE__, Keyword.put(opts, :session_id, session_id)) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            if Process.alive?(pid),
              do: {:ok, pid},
              else: retry_start(session_id, opts, attempts)

          _other when attempts > 0 ->
            retry_start(session_id, opts, attempts)

          other ->
            other
        end
    end
  end

  defp retry_start(session_id, opts, attempts) when attempts > 0 do
    Process.sleep(1)
    ensure_started(session_id, opts, attempts - 1)
  end

  defp retry_start(_session_id, _opts, 0), do: {:error, :session_start_unavailable}

  @doc "Attaches a client to the session and returns its current snapshot."
  @spec attach(name(), Identity.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach(server, client, opts \\ []),
    do: GenServer.call(server, {:attach, client, self(), opts})

  @doc "Detaches a client without stopping session work."
  @spec detach(name(), Identity.t()) :: :ok | {:error, term()}
  def detach(server, client), do: GenServer.call(server, {:detach, client})

  @doc "Queues a detach without waiting for runtime startup work."
  @spec detach_async(name(), Identity.t()) :: :ok
  def detach_async(server, client), do: GenServer.cast(server, {:detach, client})

  @doc "Returns the current semantic state."
  @spec state(name()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @doc "Returns the exact durable generation fence for this owner."
  @spec generation(name()) :: {:ok, Generation.t()} | {:error, term()}
  def generation(server), do: GenServer.call(server, :generation)

  @doc "Configures a runtime that will be owned by this session."
  @spec configure_runtime(name(), String.t(), module(), term(), keyword()) :: :ok | {:error, term()}
  def configure_runtime(server, client_id, runtime, agent, opts) do
    GenServer.call(server, {:configure_runtime, client_id, runtime, agent, opts}, :infinity)
  end

  @doc "Returns bounded runtime information for one attached client."
  @spec runtime_info(name(), String.t()) :: {:ok, map()} | {:error, term()}
  def runtime_info(server, client_id), do: GenServer.call(server, {:runtime_info, client_id})

  @doc "Starts one configured runtime turn."
  @spec start_turn(name(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @doc "Allocates the next Console sequence for an owner-built event."
  @spec next_sequence(name()) :: non_neg_integer()
  def next_sequence(server), do: GenServer.call(server, :next_sequence)

  @doc "Admits an identity-bound worker result."
  @spec admit_result(name(), Identity.t(), term()) :: {:ok, term()} | {:error, term()}
  def admit_result(server, identity, result) do
    GenServer.call(server, {:admit_result, identity, result})
  end

  @doc "Pulls one bounded canonical output batch for an exact attachment."
  @spec output(name(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:gap, map()} | :empty | {:error, term()}
  def output(server, session_id, client_id, attachment_id) do
    GenServer.call(server, {:output, session_id, client_id, attachment_id})
  end

  @doc "Acknowledges one exact bounded output batch."
  @spec ack_output(name(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def ack_output(server, session_id, client_id, attachment_id, token) do
    GenServer.call(server, {:ack_output, session_id, client_id, attachment_id, token})
  end

  @doc "Returns bounded delivery measurements for proof and diagnosis."
  @spec delivery_measurements(name(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delivery_measurements(server, client_id, attachment_id) do
    GenServer.call(server, {:delivery_measurements, client_id, attachment_id})
  end

  @doc "Runs one facade operation for an exact bounded client attachment."
  @spec client_operation(name(), map(), term()) :: term()
  def client_operation(server, identity, operation) do
    GenServer.call(server, {:client_operation, identity, operation}, :infinity)
  end

  @doc "Begins bounded recovery for one exact delivery gap."
  @spec begin_recovery(name(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def begin_recovery(server, session_id, client_id, attachment_id, gap_id) do
    GenServer.call(server, {:begin_recovery, session_id, client_id, attachment_id, gap_id})
  end

  @doc "Returns the bounded suffix for one exact recovery transaction."
  @spec replay_recovery(name(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def replay_recovery(server, session_id, client_id, attachment_id, recovery_token) do
    GenServer.call(
      server,
      {:replay_recovery, session_id, client_id, attachment_id, recovery_token}
    )
  end

  @doc "Completes one exact recovery transaction."
  @spec complete_recovery(name(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def complete_recovery(server, session_id, client_id, attachment_id, completion_token) do
    GenServer.call(
      server,
      {:complete_recovery, session_id, client_id, attachment_id, completion_token}
    )
  end

  @doc "Stops one live session server."
  @spec stop(name()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 5_000)
  catch
    :exit, {:noproc, _info} -> :ok
    :exit, :shutdown -> :ok
    :exit, {:shutdown, _info} -> :ok
    :exit, {{:shutdown, _info}, {GenServer, :stop, _args}} -> :ok
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Generation.claim(session_id, generation_options(opts)) do
      {:ok, fence} ->
        session =
          Identity.new!(:session,
            id: session_id,
            generation: fence.generation,
            owner_instance_id: fence.owner_instance_id
          )

        {:ok,
         %{
           session: session,
           fence: fence,
           generation_options: generation_options(opts),
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

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:attach, client, pid, opts}, _from, state) do
    with :ok <- exact_identity_fence(state, client),
         {:ok, state, reply} <- attach_client(state, client, pid, opts) do
      {:reply, {:ok, reply}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, client}, _from, state) do
    case exact_identity_fence(state, client) do
      :ok ->
        case Map.pop(state.clients, client.id) do
          {nil, _clients} ->
            {:reply, {:error, :not_attached}, state}

          {client, clients} ->
            cleanup_client(client)
            {:reply, :ok, %{state | clients: clients}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state.state, state}
  def handle_call(:generation, _from, state), do: {:reply, {:ok, state.fence}, state}

  def handle_call({:client_operation, identity, operation}, from, state) do
    case fetch_exact_client(state, identity) do
      {:ok, client} -> execute_client_operation(operation, from, state, client)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

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
    case Map.fetch(state.clients, client_id) do
      {:ok, client} -> execute_start_turn(state, client, prompt, opts)
      :error -> {:reply, {:error, :not_attached}, state}
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

      stale_request_fence?(state, request) ->
        {:reply, {:error, :stale_generation}, state}

      Map.has_key?(state.completed, request.id) ->
        {:reply, Map.fetch!(state.completed, request.id), state}

      state.active && state.active.request.id == request.id && state.active.pending_result != nil ->
        {:reply, state.active.pending_result, state}

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
      owner = active.relay

      review = matching_pending_review(pending, review)

      task =
        start_task(state, fn ->
          safe_call(fn -> respond.(decision, pending, review, opts, owner) end)
        end)

      tasks =
        put_task(
          state.tasks,
          task,
          {:review, request.id, decision, review_id(review)},
          fence_token(state)
        )

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

  def handle_call({:output, session_id, client_id, attachment_id}, _from, state) do
    identity = delivery_identity(session_id, client_id, attachment_id)

    case fetch_bounded_client(state, client_id, attachment_id) do
      {:ok, client} -> handle_output_pull(state, client_id, client, identity)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ack_output, session_id, client_id, attachment_id, token}, _from, state) do
    identity = delivery_identity(session_id, client_id, attachment_id)

    case fetch_bounded_client(state, client_id, attachment_id) do
      {:ok, client} -> handle_output_ack(state, client_id, client, identity, token)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delivery_measurements, client_id, attachment_id}, _from, state) do
    case fetch_bounded_client(state, client_id, attachment_id) do
      {:ok, client} -> {:reply, {:ok, Delivery.measurements(client.delivery)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:begin_recovery, session_id, client_id, attachment_id, gap_id},
        _from,
        state
      ) do
    identity = delivery_identity(session_id, client_id, attachment_id)

    case fetch_bounded_client(state, client_id, attachment_id) do
      {:ok, client} ->
        case Recovery.begin(state.state, client.delivery, identity, gap_id) do
          {:ok, delivery, snapshot} ->
            client = client |> cancel_delivery_timer() |> put_delivery(delivery)
            {:reply, {:ok, snapshot}, put_client(state, client_id, client)}

          {:error, reason, _delivery} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:replay_recovery, session_id, client_id, attachment_id, recovery_token},
        _from,
        state
      ) do
    identity = delivery_identity(session_id, client_id, attachment_id)

    case fetch_bounded_client(state, client_id, attachment_id) do
      {:ok, client} ->
        case Recovery.replay(state.state, client.delivery, identity, recovery_token) do
          {:ok, delivery, suffix} ->
            {:reply, {:ok, suffix}, put_client(state, client_id, put_delivery(client, delivery))}

          {:error, reason, _delivery} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:complete_recovery, session_id, client_id, attachment_id, completion_token},
        _from,
        state
      ) do
    identity = delivery_identity(session_id, client_id, attachment_id)

    case fetch_bounded_client(state, client_id, attachment_id) do
      {:ok, client} ->
        case Recovery.complete(client.delivery, identity, completion_token) do
          {:ok, delivery, receipt, advisory?} ->
            client = put_delivery(client, delivery)
            if advisory?, do: send_ready(client)
            {:reply, {:ok, receipt}, put_client(state, client_id, client)}

          {:error, reason, _delivery} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:admit_result, identity, result}, _from, state) do
    case exact_identity_fence(state, identity) do
      :ok ->
        admission = Map.get_lazy(state.admissions, identity.id, fn -> IdentityAdmission.new(identity) end)

        case IdentityAdmission.admit(admission, identity) do
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

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:detach, client}, state) do
    case exact_identity_fence(state, client) do
      :ok ->
        case Map.pop(state.clients, client.id) do
          {nil, _clients} ->
            {:noreply, state}

          {client, clients} ->
            cleanup_client(client)
            {:noreply, %{state | clients: clients}}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:generation_message, fence, {:jidoka_turn_event, event}},
        %{active: active} = state
      )
      when not is_nil(active) do
    if current_fence_token?(state, fence) do
      state = project_runtime_event(state, event)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:projection_terminal_timeout, fence, request_id, token}, state) do
    if current_fence_token?(state, fence) do
      handle_projection_terminal_timeout(state, request_id, token)
    else
      {:noreply, state}
    end
  end

  def handle_info({:delivery_ack_timeout, fence, attachment_id, timer_token}, state) do
    if current_fence_token?(state, fence) do
      clients =
        Map.new(state.clients, fn {client_id, client} ->
          {client_id, timeout_client(client, attachment_id, timer_token, state.state.sequence)}
        end)

      {:noreply, %{state | clients: clients}}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) and is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {{kind, _pid, fence}, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}

    if current_fence_token?(state, fence),
      do: {:noreply, complete_task(state, kind, outcome)},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.tasks, ref) do
    {{kind, _pid, fence}, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}

    if current_fence_token?(state, fence),
      do: {:noreply, complete_task(state, kind, {:error, {:runtime_task_failed, reason}})},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    clients =
      Enum.reduce(state.clients, %{}, fn {id, client}, clients ->
        if client.ref == ref do
          cleanup_client(client)
          clients
        else
          Map.put(clients, id, client)
        end
      end)

    {:noreply, %{state | clients: clients}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_projection_terminal_timeout(state, request_id, token) do
    case state.active do
      %{request: %{id: ^request_id}, terminal_timer: %{token: ^token}, terminal_result: result}
      when not is_nil(result) ->
        active = state.active

        state =
          state
          |> admit_owner_event(terminal_type(result), active.request, result_payload(result))
          |> conclude_runtime_result(result)

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.tasks
    |> Map.values()
    |> Enum.each(fn {_kind, pid, _fence} ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    stop_generation_relay(state.active)
    close_runtime(state.runtime)
    _result = Generation.release(state.fence, state.generation_options)
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

      tasks =
        put_task(state.tasks, task, {:cancel, request.id, List.wrap(waiter)}, fence_token(state))

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
    owner = self()
    relay = spawn(fn -> generation_relay(owner, fence_token(state)) end)

    case safe_call(fn -> spec.start.(relay) end) do
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
          cancel_waiters: [],
          pending_result: nil,
          terminal_result: nil,
          terminal_timer: nil,
          relay: relay,
          projection_cursor: projection_cursor!(request.request_id)
        }

        state = %{state | active: active}

        started_payload =
          %{"status" => "running"}
          |> maybe_put("prompt", Map.get(spec, :prompt))

        state = admit_owner_event(state, "run_started", request, started_payload)
        task = start_task(state, fn -> safe_call(fn -> spec.await.(raw_request) end) end)
        tasks = put_task(state.tasks, task, {:await, request.id}, fence_token(state))
        {:ok, request, %{state | tasks: tasks}}

      {:ok, {:error, reason}} ->
        stop_generation_relay(%{relay: relay})
        {:error, reason}

      {:ok, other} ->
        stop_generation_relay(%{relay: relay})
        {:error, {:invalid_runtime_request, other}}

      {:error, reason} ->
        stop_generation_relay(%{relay: relay})
        {:error, reason}
    end
  end

  defp public_request(state, raw_request, spec) do
    identity_opts = [
      session_id: state.session.id,
      generation: state.session.generation,
      owner_instance_id: state.session.owner_instance_id
    ]

    request_id =
      Map.get(spec, :request_id) || raw_request_id(raw_request) ||
        Identity.new!(:request, identity_opts).id

    run_id = Map.get(spec, :run_id) || Identity.new!(:run, identity_opts).id

    %Request{
      id: Identity.new!(:request, identity_opts).id,
      request_id: request_id,
      run_id: run_id,
      session_id: state.session.id,
      generation: state.session.generation,
      owner_instance_id: state.session.owner_instance_id
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

  defp put_task(tasks, %Task{ref: ref, pid: pid}, kind, fence),
    do: Map.put(tasks, ref, {kind, pid, fence})

  defp complete_task(state, {:await, request_id}, outcome) do
    if active_request?(state, request_id),
      do: complete_runtime_result(state, unwrap_task(outcome)),
      else: state
  end

  defp complete_task(state, {:review, request_id, decision, approval_id}, outcome) do
    if active_request?(state, request_id) do
      state
      |> admit_permission_decision(decision, approval_id)
      |> complete_runtime_result(unwrap_task(outcome))
    else
      state
    end
  end

  defp complete_task(state, {:cancel, request_id, waiters}, outcome) do
    result = unwrap_task(outcome)

    state =
      if active_request?(state, request_id) do
        active = state.active

        state =
          admit_owner_event(state, "control_completed", active.request, %{
            "control" => "cancel",
            "result" => public_control_result(result)
          })

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

    if successful_cancel_still_active?(state, request_id, result) do
      update_in(state.active.cancel_waiters, fn cancel_waiters ->
        cancel_waiters ++ Enum.map(waiters, &{&1, result})
      end)
    else
      Enum.each(waiters, &GenServer.reply(&1, result))
      state
    end
  end

  defp successful_cancel_still_active?(state, request_id, {:ok, %Jidoka.Cancellation{}}),
    do: active_request?(state, request_id)

  defp successful_cancel_still_active?(_state, _request_id, _result), do: false

  defp unwrap_task({:ok, result}), do: result
  defp unwrap_task({:error, _reason} = error), do: error
  defp unwrap_task(result), do: result

  defp complete_runtime_result(state, result) do
    active = state.active
    state = update_runtime_session(state, result)
    pending? = pending_result?(result)

    cond do
      pending? ->
        state = admit_pending_review(state, result)
        Enum.each(active.waiters, &GenServer.reply(&1, result))
        %{state | active: %{active | pending_result: result, waiters: []}}

      match?(%RuntimeResult{outcome: %Cancelled{}}, result) ->
        state
        |> admit_owner_event("run_failed", active.request, result_payload(result))
        |> conclude_runtime_result(result)

      active.runtime? ->
        admit_runtime_terminal_result(state, result)

      true ->
        state
        |> admit_owner_event(terminal_type(result), active.request, result_payload(result))
        |> conclude_runtime_result(result)
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
  defp terminal_type(%RuntimeResult{outcome: %Cancelled{}}), do: "run_failed"
  defp terminal_type({:error, _reason}), do: "run_failed"
  defp terminal_type(_result), do: "run_completed"

  defp result_payload(%RuntimeResult{outcome: %Ok{content: content}} = result) do
    %{
      "status" => Atom.to_string(RuntimeResult.status(result)),
      "content" => bounded_text(content),
      "error" => nil,
      "view" => result_view(result)
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

  defp result_view(%RuntimeResult{outcome: %Ok{coding_reviews: reviews}}) do
    %{"coding_reviews" => portable_record(reviews)}
  end

  defp admit_pending_review(state, %RuntimeResult{outcome: %PendingReview{reviews: reviews}}) do
    review = List.first(reviews) || %{}

    attrs = %{
      "approval_id" => review_id(review) || "approval_#{state.active.request.id}",
      "principal" => "user",
      "scope" => review_field(review, :operation) || "session",
      "review" => portable_record(review)
    }

    admit_owner_event(state, "permission_requested", state.active.request, attrs)
  end

  defp admit_pending_review(state, _result), do: state

  defp admit_permission_decision(state, decision, approval_id) do
    attrs = %{
      "approval_id" => approval_id || "approval_#{state.active.request.id}",
      "decision" => if(decision == :approve, do: "approved", else: "denied")
    }

    admit_owner_event(state, "permission_decided", state.active.request, attrs)
  end

  defp matching_pending_review(
         %RuntimeResult{outcome: %PendingReview{reviews: reviews}},
         candidate
       ) do
    id = review_id(candidate)
    Enum.find(reviews, candidate, &(review_id(&1) == id))
  end

  defp matching_pending_review(_pending, candidate), do: candidate

  defp review_id(review), do: review_field(review, :interrupt_id) || review_field(review, :id)

  defp review_field(review, key) when is_map(review) do
    Map.get(review, key) || Map.get(review, Atom.to_string(key))
  end

  defp review_field(_review, _key), do: nil

  defp public_control_result({:error, reason}),
    do: %{"status" => "error", "reason" => portable_reason(reason)}

  defp public_control_result({:ok, result}),
    do: %{"status" => "ok", "result" => portable_reason(result)}

  defp public_control_result(result),
    do: %{"status" => "ok", "result" => portable_reason(result)}

  defp portable_record(%module{} = value) when module not in [Date, Time, DateTime, NaiveDateTime] do
    value |> Map.from_struct() |> portable_record()
  end

  defp portable_record(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), portable_record(item)} end)
  end

  defp portable_record(value) when is_list(value), do: Enum.map(value, &portable_record/1)

  defp portable_record(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
       do: inspect(value)

  defp portable_record(value) when is_atom(value), do: Atom.to_string(value)
  defp portable_record(value), do: value

  defp stop_await_task(state, request_id) do
    case Enum.find(state.tasks, fn {_ref, {kind, _pid, _fence}} -> kind == {:await, request_id} end) do
      {ref, {_kind, pid, _fence}} ->
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
      request: active.request,
      cursor: active.projection_cursor,
      jidoka_request_id: active.request.request_id
    ]

    case Projection.project(event, opts) do
      {:ok, projected, cursor} ->
        case admit_event_state(state, projected) do
          {:ok, state} ->
            put_in(state.active.projection_cursor, cursor)

          {:error, _reason, state} ->
            state
        end

      {:hold_terminal, _candidate, cursor} ->
        state = put_in(state.active.projection_cursor, cursor)
        finalize_runtime_terminal(state)

      {:ignore, :duplicate, _cursor} ->
        state

      {:error, _reason, _cursor} ->
        state
    end
  end

  defp admit_runtime_terminal_result(state, result) do
    active = state.active
    payload = result_payload(result)

    candidate = %{
      "type" => terminal_type(result),
      "fields" => terminal_fields(terminal_type(result), active.request, payload)
    }

    identity = %{
      "session_id" => state.session.id,
      "request_id" => active.request.request_id,
      "run_id" => active.request.run_id
    }

    case Projection.admit_result(active.projection_cursor, identity, candidate) do
      {:ok, cursor} ->
        state
        |> put_in([:active, :projection_cursor], cursor)
        |> put_in([:active, :terminal_result], result)
        |> finalize_runtime_terminal()
        |> schedule_terminal_fallback()

      {:ignore, :duplicate, _cursor} ->
        state

      {:error, _reason, _cursor} ->
        state
    end
  end

  defp finalize_runtime_terminal(%{active: nil} = state), do: state

  defp finalize_runtime_terminal(state) do
    active = state.active

    if active.terminal_result && Projection.terminal_ready?(active.projection_cursor) do
      case Projection.finalize(active.projection_cursor, sequence: state.state.sequence + 1) do
        {:ok, event, cursor} ->
          case admit_event_state(state, event) do
            {:ok, state} ->
              state
              |> put_in([:active, :projection_cursor], cursor)
              |> conclude_runtime_result(active.terminal_result)

            {:error, _reason, state} ->
              state
          end

        {:error, _reason, _cursor} ->
          state
      end
    else
      state
    end
  end

  defp conclude_runtime_result(state, result) do
    active = state.active
    cancel_terminal_timer(active)
    stop_generation_relay(active)
    Enum.each(active.waiters, &GenServer.reply(&1, result))
    Enum.each(active.cancel_waiters, fn {waiter, reply} -> GenServer.reply(waiter, reply) end)
    put_completed(%{state | active: nil}, active.request.id, result)
  end

  defp schedule_terminal_fallback(%{active: nil} = state), do: state

  defp schedule_terminal_fallback(%{active: %{terminal_timer: timer}} = state)
       when not is_nil(timer),
       do: state

  defp schedule_terminal_fallback(state) do
    active = state.active

    if active.terminal_result && not Projection.terminal_ready?(active.projection_cursor) do
      token = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {:projection_terminal_timeout, fence_token(state), active.request.id, token},
          @terminal_event_wait_ms
        )

      put_in(state.active.terminal_timer, %{token: token, ref: timer_ref})
    else
      state
    end
  end

  defp cancel_terminal_timer(%{terminal_timer: %{ref: ref}}), do: Process.cancel_timer(ref)
  defp cancel_terminal_timer(_active), do: false

  defp terminal_fields("run_completed", request, payload) do
    %{
      "run_id" => request.run_id,
      "outcome_id" => request.id,
      "content" => payload["content"],
      "view" => payload["view"] || %{}
    }
  end

  defp terminal_fields("run_failed", request, payload) do
    %{"run_id" => request.run_id, "reason" => payload["error"] || payload["status"]}
  end

  defp projection_cursor!(request_id) do
    case Projection.new_cursor(request_id) do
      {:ok, cursor} -> cursor
      {:error, reason} -> raise ArgumentError, "invalid projection cursor: #{inspect(reason)}"
    end
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
          %{
            "kind" => "request",
            "id" => request.id,
            "session_id" => state.session.id,
            "generation" => request.generation,
            "owner_instance_id" => request.owner_instance_id
          }
        ]
      }
      |> Map.merge(owner_event_fields(type, request, extra))

    with {:ok, event} <- Event.classify(attrs),
         {:ok, state} <- admit_event_state(state, event) do
      state
    else
      _error -> state
    end
  end

  defp admit_control(state, type, request, control),
    do: admit_owner_event(state, type, request, %{"control" => control})

  defp owner_event_fields("run_started", request, extra) do
    Map.merge(extra, %{"run_id" => request.run_id, "turn_id" => request.request_id})
  end

  defp owner_event_fields("run_completed", request, extra) do
    %{
      "run_id" => request.run_id,
      "outcome_id" => request.id,
      "content" => extra["content"],
      "view" => extra["view"] || %{}
    }
  end

  defp owner_event_fields("run_failed", request, extra) do
    %{"run_id" => request.run_id, "reason" => extra["error"] || extra["status"]}
  end

  defp owner_event_fields("control_requested", request, extra) do
    %{"control_id" => request.id, "control" => extra["control"]}
  end

  defp owner_event_fields("control_completed", request, extra) do
    %{"control_id" => request.id, "result" => extra["result"] || extra["control"]}
  end

  defp owner_event_fields("permission_requested", _request, extra) do
    %{
      "approval_id" => extra["approval_id"],
      "principal" => extra["principal"],
      "scope" => extra["scope"],
      "review" => extra["review"]
    }
  end

  defp owner_event_fields("permission_decided", _request, extra) do
    %{
      "approval_id" => extra["approval_id"],
      "decision" => extra["decision"]
    }
  end

  defp admit_event_state(state, event) do
    with {:ok, semantic} <- Reducer.apply_event(state.state, event),
         {:ok, _durable} <- History.append(event, semantic, state.fence, state.generation_options) do
      clients = publish(state.clients, event, semantic)

      {:ok,
       %{
         state
         | state: semantic,
           clients: clients,
           reserved: max(state.reserved, semantic.sequence)
       }}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
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
      stale_request_fence?(state, request) -> {:error, :stale_generation}
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

  defp stale_request_fence?(state, request) do
    request.generation != state.session.generation or
      request.owner_instance_id != state.session.owner_instance_id
  end

  defp exact_identity_fence(state, identity) do
    cond do
      identity.session_id != state.session.id ->
        {:error, :cross_session_result}

      identity.generation != state.session.generation or
          identity.owner_instance_id != state.session.owner_instance_id ->
        {:error, :stale_generation}

      true ->
        :ok
    end
  end

  defp publish(clients, event, session_state) do
    Map.new(clients, fn {id, client} ->
      {id, deliver(client, event, session_state, true)}
    end)
  end

  defp publish_silent(clients, event, session_state) do
    Map.new(clients, fn {id, client} ->
      {id, deliver(client, event, session_state, false)}
    end)
  end

  defp deliver(client, event, _session_state, notify?) do
    case Delivery.offer(client.delivery, event) do
      {:ok, delivery, advisory?} ->
        client = put_delivery(client, delivery)
        if advisory? and notify?, do: send_ready(client)
        client

      {:duplicate, delivery} ->
        put_delivery(client, delivery)

      {:gap, delivery, _gap, advisory?} ->
        client = client |> cancel_delivery_timer() |> put_delivery(delivery)
        if advisory? and notify?, do: send_ready(client)
        client
    end
  end

  defp notify_clients(clients), do: Enum.each(clients, fn {_id, client} -> send_ready(client) end)

  defp fetch_bounded_client(state, client_id, attachment_id) do
    case Map.fetch(state.clients, client_id) do
      {:ok, %{attachment: %{id: ^attachment_id}} = client} -> {:ok, client}
      {:ok, _client} -> {:error, :delivery_identity_mismatch}
      :error -> {:error, :not_attached}
    end
  end

  defp fetch_exact_client(state, identity) do
    session_id = identity[:session_id] || identity["session_id"]
    client_id = identity[:client_id] || identity["client_id"]
    attachment_id = identity[:attachment_id] || identity["attachment_id"]
    generation = identity[:generation] || identity["generation"]
    owner_instance_id = identity[:owner_instance_id] || identity["owner_instance_id"]

    cond do
      session_id != state.session.id ->
        {:error, :delivery_identity_mismatch}

      generation != state.session.generation or owner_instance_id != state.session.owner_instance_id ->
        {:error, :stale_generation}

      true ->
        fetch_bounded_client(state, client_id, attachment_id)
    end
  end

  defp execute_client_operation(:detach, _from, state, client) do
    cleanup_client(client)
    clients = Map.delete(state.clients, client.identity.id)
    {:reply, :ok, %{state | clients: clients}}
  end

  defp execute_client_operation(:runtime_info, _from, state, _client) do
    {:reply, {:ok, runtime_info_value(state)}, state}
  end

  defp execute_client_operation(:status, _from, state, client) do
    status = %{
      "session_id" => state.session.id,
      "client_id" => client.identity.id,
      "attachment_id" => client.attachment.id,
      "sequence" => state.state.sequence,
      "active_request" => active_public_request(state),
      "delivery" => Atom.to_string(client.delivery.status),
      "process_lifetime" => true
    }

    {:reply, {:ok, status}, state}
  end

  defp execute_client_operation(:snapshot, _from, state, _client) do
    {:reply, {:ok, Reducer.snapshot(state.state)}, state}
  end

  defp execute_client_operation(:output, _from, state, client) do
    identity = delivery_identity(state.session, client.identity.id, client.attachment.id)
    handle_output_pull(state, client.identity.id, client, identity)
  end

  defp execute_client_operation({:delivery, token}, _from, state, client) do
    identity = delivery_identity(state.session, client.identity.id, client.attachment.id)
    handle_output_ack(state, client.identity.id, client, identity, token)
  end

  defp execute_client_operation(:delivery_measurements, _from, state, client) do
    {:reply, {:ok, Delivery.measurements(client.delivery)}, state}
  end

  defp execute_client_operation({:recovery, :recover, gap_id}, _from, state, client) do
    identity = delivery_identity(state.session, client.identity.id, client.attachment.id)

    case Recovery.begin(state.state, client.delivery, identity, gap_id) do
      {:ok, delivery, snapshot} ->
        client = client |> cancel_delivery_timer() |> put_delivery(delivery)
        {:reply, {:ok, snapshot}, put_client(state, client.identity.id, client)}

      {:error, reason, _delivery} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation({:recovery, :replay, token}, _from, state, client) do
    identity = delivery_identity(state.session, client.identity.id, client.attachment.id)

    case Recovery.replay(state.state, client.delivery, identity, token) do
      {:ok, delivery, suffix} ->
        {:reply, {:ok, suffix}, put_client(state, client.identity.id, put_delivery(client, delivery))}

      {:error, reason, _delivery} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation({:recovery, :resume, token}, _from, state, client) do
    identity = delivery_identity(state.session, client.identity.id, client.attachment.id)

    case Recovery.complete(client.delivery, identity, token) do
      {:ok, delivery, receipt, advisory?} ->
        client = put_delivery(client, delivery)
        if advisory?, do: send_ready(client)
        {:reply, {:ok, receipt}, put_client(state, client.identity.id, client)}

      {:error, reason, _delivery} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation({:configure_runtime, runtime, agent, opts}, _from, state, _client) do
    configure_client_runtime(state, runtime, agent, opts)
  end

  defp execute_client_operation({:start_turn, prompt, opts}, _from, state, client) do
    execute_start_turn(state, client, prompt, opts)
  end

  defp execute_client_operation({:start_operation, spec}, _from, state, _client) do
    with :ok <- require_idle(state),
         {:ok, normalized} <- normalize_operation(spec),
         {:ok, request, state} <- begin_operation(state, normalized) do
      {:reply, {:ok, request}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation({:await, %Request{} = request}, from, state, _client) do
    await_client_request(state, request, from)
  end

  defp execute_client_operation({:cancel, %Request{} = request, opts}, _from, state, client) do
    start_cancel(state, client.identity.id, request, opts, nil)
  end

  defp execute_client_operation({:cancel_wait, %Request{} = request, opts}, from, state, client) do
    start_cancel(state, client.identity.id, request, opts, from)
  end

  defp execute_client_operation(
         {:respond_review, decision, %Request{} = request, review, opts},
         _from,
         state,
         client
       ) do
    respond_to_review(state, client.identity.id, decision, request, review, opts)
  end

  defp execute_client_operation({:input, operation, value}, _from, state, client) do
    case apply_client_input(state, client, operation, value) do
      {:ok, result, state} -> {:reply, {:ok, result}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation({:effect, effect, idempotency_key}, _from, state, client) do
    protocol_effect = Effect.to_protocol(effect)

    payload = %{
      "command_id" => effect.command_id,
      "effect" => protocol_effect
    }

    fields = %{"command_id" => effect.command_id, "effect" => protocol_effect}

    case admit_durable_client_event(state, client, :invoke, idempotency_key, payload, "command_effected", fields) do
      {:ok, admission, state} ->
        {:reply, {:ok, Map.put(effect, :receipt, admission.receipt)}, state}

      {:error, reason, _state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation({:admission_receipt, operation_id}, _from, state, _client) do
    case Admission.receipt(operation_id, state.generation_options) do
      {:ok, %{"session_id" => session_id} = receipt} when session_id == state.session.id ->
        {:reply, {:ok, receipt}, state}

      {:ok, _receipt} ->
        {:reply, {:error, :cross_session_result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp execute_client_operation(_operation, _from, state, _client) do
    {:reply, {:error, :unsupported_client_operation}, state}
  end

  defp configure_client_runtime(state, runtime, agent, opts) do
    cond do
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

  defp await_client_request(state, request, from) do
    cond do
      request.session_id != state.session.id ->
        {:reply, {:error, :cross_session_result}, state}

      stale_request_fence?(state, request) ->
        {:reply, {:error, :stale_generation}, state}

      Map.has_key?(state.completed, request.id) ->
        {:reply, Map.fetch!(state.completed, request.id), state}

      state.active && state.active.request.id == request.id && state.active.pending_result != nil ->
        {:reply, state.active.pending_result, state}

      state.active && state.active.request.id == request.id ->
        active = Map.update!(state.active, :waiters, &(&1 ++ [from]))
        {:noreply, %{state | active: active}}

      true ->
        {:reply, {:error, :stale_request}, state}
    end
  end

  defp respond_to_review(state, client_id, decision, request, review, opts) do
    with :ok <- require_attached(state, client_id),
         true <- decision in [:approve, :deny],
         {:ok, active} <- matching_active(state, request),
         pending when not is_nil(pending) <- active.pending_result,
         respond when is_function(respond, 5) <- active.respond_review do
      owner = active.relay

      review = matching_pending_review(pending, review)

      task =
        start_task(state, fn ->
          safe_call(fn -> respond.(decision, pending, review, opts, owner) end)
        end)

      tasks =
        put_task(
          state.tasks,
          task,
          {:review, request.id, decision, review_id(review)},
          fence_token(state)
        )

      active = %{active | pending_result: nil}
      {:reply, {:ok, :requested}, %{state | active: active, tasks: tasks}}
    else
      false -> {:reply, {:error, :invalid_review_decision}, state}
      nil -> {:reply, {:error, :review_not_pending}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp execute_start_turn(state, client, prompt, opts) do
    idempotency_key = Keyword.get(opts, :idempotency_key)
    sequence = state.state.sequence + 1

    prepared =
      Admission.prepare(
        :start_turn,
        %{
          "operation" => "start_turn",
          "prompt" => prompt,
          "metadata" => turn_admission_metadata(opts),
          "input_id" =>
            stable_admission_target(
              state.session.id,
              :start_turn,
              client.identity.id,
              idempotency_key
            ),
          "client_id" => client.identity.id
        },
        session_id: state.session.id,
        principal_id: client.identity.id,
        idempotency_key: idempotency_key,
        generation: state.session.generation,
        sequence: sequence
      )

    case prepared do
      {:ok, prepared} -> execute_prepared_start_turn(state, client, prompt, opts, prepared)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp execute_prepared_start_turn(state, client, prompt, opts, prepared) do
    case existing_admission(prepared, state) do
      {:ok, receipt} ->
        {:reply, {:ok, %{request: nil, receipt: receipt, duplicate: true}}, state}

      :missing ->
        case runtime_operation(state.runtime, prompt, opts) do
          {:ok, spec} -> start_new_durable_turn(state, client, prompt, spec, prepared)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_new_durable_turn(state, client, _prompt, spec, prepared) do
    fields = %{"input_id" => prepared.target_id, "client_id" => client.identity.id}

    with :ok <- require_idle(state),
         {:ok, event} <-
           durable_client_event(
             state,
             client,
             prepared.operation_id,
             "input_admitted",
             fields,
             state.state.sequence + 1
           ),
         {:ok, semantic} <- Reducer.apply_event(state.state, event),
         {:ok, admission} <-
           Admission.commit(prepared, event, semantic, state.fence, state.generation_options) do
      state = committed_admission_state(state, event, semantic, admission, false)

      case Admission.transition(
             prepared.operation_id,
             "started",
             state.fence,
             state.generation_options
           ) do
        {:ok, started} ->
          start_admitted_turn(state, spec, prepared, started)

        {:error, reason} ->
          notify_clients(state.clients)
          {:reply, {:error, {:admitted_not_started, admission.receipt, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp start_admitted_turn(state, spec, prepared, started) do
    case begin_operation(state, spec) do
      {:ok, request, state} ->
        notify_clients(state.clients)
        {:reply, {:ok, %{request: request, receipt: started.receipt, duplicate: false}}, state}

      {:error, reason} ->
        terminal =
          Admission.transition(
            prepared.operation_id,
            "terminal",
            state.fence,
            state.generation_options
          )

        receipt = transition_receipt(terminal, started.receipt)
        notify_clients(state.clients)
        {:reply, {:error, {:admitted_not_started, receipt, reason}}, state}
    end
  end

  defp existing_admission(prepared, state) do
    case Admission.receipt(prepared.operation_id, state.generation_options) do
      {:ok, receipt} ->
        if get_in(receipt, ["payload", "payload_digest"]) == prepared.payload_digest do
          {:ok, receipt}
        else
          {:error, {:idempotency_conflict, receipt["id"]}}
        end

      {:error, {:admission_receipt_not_found, _operation_id}} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stable_admission_target(session_id, operation, principal_id, idempotency_key) do
    case Admission.target_id(session_id, operation, principal_id, idempotency_key) do
      {:ok, target_id} -> target_id
      {:error, _reason} -> nil
    end
  end

  defp turn_admission_metadata(opts) do
    case Keyword.get(opts, :turn_opts, []) do
      value when is_list(value) -> Keyword.get(value, :context, %{})
      value -> value
    end
  end

  defp apply_client_input(state, client, :send, input) do
    payload = input_payload(input, client, :send)
    fields = %{"input_id" => input.identity.id, "client_id" => client.identity.id}

    with :ok <- validate_client_input(state, client, input),
         {:ok, admission, state} <-
           admit_durable_client_event(
             state,
             client,
             :send,
             input.idempotency_key,
             payload,
             "input_admitted",
             fields
           ) do
      input = Map.put(input, :receipt, admission.receipt)
      state = if admission.duplicate, do: state, else: %{state | inputs: bounded_append(state.inputs, input)}
      {:ok, input, state}
    end
  end

  defp apply_client_input(state, client, operation, input) when operation in [:steer, :queue] do
    queue = if operation == :steer, do: :steering, else: :follow_up

    payload = input_payload(input, client, operation)
    fields = %{"input_id" => input.identity.id, "client_id" => client.identity.id}

    with :ok <- validate_client_input(state, client, input),
         {:ok, admission, state} <-
           admit_durable_client_event(
             state,
             client,
             operation,
             input.idempotency_key,
             payload,
             "input_admitted",
             fields
           ) do
      input = Map.put(input, :receipt, admission.receipt)

      if admission.duplicate do
        {:ok, input, state}
      else
        item = input_queue_item(input, client)

        with {:ok, queues} <- Queue.add(state.state.queues, queue, item),
             {:ok, state} <- admit_queue_event(state, client, queue, queues[queue]) do
          {:ok, input, %{state | inputs: bounded_append(state.inputs, input)}}
        end
      end
    end
  end

  defp apply_client_input(
         state,
         client,
         :remove,
         %{queue: queue, input_id: input_id, idempotency_key: idempotency_key}
       ) do
    payload = %{
      "command_id" => "remove",
      "queue" => Atom.to_string(queue),
      "input_id" => input_id
    }

    sequence = state.state.sequence + 1

    prepared =
      Admission.prepare(:remove, payload,
        session_id: state.session.id,
        principal_id: client.identity.id,
        idempotency_key: idempotency_key,
        generation: state.session.generation,
        sequence: sequence
      )

    case prepared do
      {:ok, prepared} ->
        case existing_admission(prepared, state) do
          {:ok, receipt} ->
            {:ok,
             %{
               operation: :remove,
               queue: queue,
               input_id: input_id,
               receipt: receipt
             }, state}

          :missing ->
            with {:ok, queues} <- Queue.remove(state.state.queues, queue, input_id),
                 fields = %{"queue" => Atom.to_string(queue), "items" => queues[queue]},
                 {:ok, admission, state} <-
                   commit_prepared_client_event(
                     state,
                     client,
                     prepared,
                     "queue_changed",
                     fields
                   ) do
              {:ok,
               %{
                 operation: :remove,
                 queue: queue,
                 input_id: input_id,
                 receipt: admission.receipt
               }, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp apply_client_input(_state, _client, _operation, _value),
    do: {:error, :invalid_client_input_operation}

  defp validate_client_input(state, client, input) do
    cond do
      input.identity.session_id != state.session.id -> {:error, :cross_session_result}
      input.client_id != client.identity.id -> {:error, :delivery_identity_mismatch}
      true -> :ok
    end
  end

  defp admit_queue_event(state, client, queue, items) do
    admit_client_event(state, client, "queue_changed", %{
      "queue" => Atom.to_string(queue),
      "items" => items
    })
  end

  defp admit_durable_client_event(
         state,
         client,
         operation,
         idempotency_key,
         payload,
         type,
         fields
       ) do
    sequence = state.state.sequence + 1

    prepared =
      Admission.prepare(operation, payload,
        session_id: state.session.id,
        principal_id: client.identity.id,
        idempotency_key: idempotency_key,
        generation: state.session.generation,
        sequence: sequence
      )

    case prepared do
      {:ok, prepared} ->
        case existing_admission(prepared, state) do
          {:ok, receipt} ->
            {:ok, %{receipt: receipt, duplicate: true}, state}

          :missing ->
            commit_prepared_client_event(state, client, prepared, type, fields)

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp commit_prepared_client_event(state, client, prepared, type, fields) do
    with {:ok, event} <-
           durable_client_event(
             state,
             client,
             prepared.operation_id,
             type,
             fields,
             state.state.sequence + 1
           ),
         {:ok, semantic} <- Reducer.apply_event(state.state, event),
         {:ok, admission} <-
           Admission.commit(
             prepared,
             event,
             semantic,
             state.fence,
             state.generation_options
           ) do
      {:ok, admission, committed_admission_state(state, event, semantic, admission)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp transition_receipt({:ok, %{receipt: receipt}}, _fallback), do: receipt
  defp transition_receipt(_result, fallback), do: fallback

  defp committed_admission_state(state, event, semantic, admission, notify? \\ true)

  defp committed_admission_state(state, event, semantic, %{duplicate: false}, notify?) do
    clients =
      if notify?,
        do: publish(state.clients, event, semantic),
        else: publish_silent(state.clients, event, semantic)

    %{
      state
      | state: semantic,
        clients: clients,
        reserved: max(state.reserved, semantic.sequence)
    }
  end

  defp committed_admission_state(state, _event, _semantic, %{duplicate: true}, _notify?), do: state

  defp durable_client_event(state, client, operation_id, type, fields, sequence) do
    attrs =
      Map.merge(fields, %{
        "type" => type,
        "id" => "evt_#{operation_id}",
        "session_id" => state.session.id,
        "sequence" => sequence,
        "durability" => "process",
        "sensitivity" => "public",
        "origin" => %{"kind" => "client", "actor_id" => client.identity.id},
        "trust" => %{"evidence" => "durable-admission", "policy" => "session-owner"},
        "identities" => [
          Identity.to_protocol(state.session),
          Identity.to_protocol(client.identity),
          Identity.to_protocol(client.attachment)
        ]
      })

    Event.classify(attrs)
  end

  defp input_payload(input, client, operation) do
    %{
      "operation" => Atom.to_string(operation),
      "input_id" => input.identity.id,
      "client_id" => client.identity.id,
      "text" => input.text
    }
  end

  defp admit_client_event(state, client, type, fields) do
    sequence = state.state.sequence + 1

    attrs =
      Map.merge(fields, %{
        "type" => type,
        "id" => "plt_client_#{client.identity.id}_#{sequence}",
        "session_id" => state.session.id,
        "sequence" => sequence,
        "durability" => "process",
        "sensitivity" => "public",
        "origin" => %{"kind" => "client", "actor_id" => client.identity.id},
        "trust" => %{"evidence" => "session-client", "policy" => "session-owner"},
        "identities" => [
          Identity.to_protocol(state.session),
          Identity.to_protocol(client.identity),
          Identity.to_protocol(client.attachment)
        ]
      })

    with {:ok, event} <- Event.classify(attrs) do
      admit_event_state(state, event)
    end
  end

  defp input_queue_item(input, client) do
    %{
      "session_id" => input.identity.session_id,
      "input_id" => input.identity.id,
      "client_id" => client.identity.id,
      "text" => input.text
    }
  end

  defp runtime_info_value(state) do
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
  end

  defp attach_client(state, client, pid, opts) do
    attachment = attachment_identity(state.session, opts)

    delivery =
      Delivery.new(
        client_id: client.id,
        session_id: state.session.id,
        attachment_id: attachment.id,
        generation: state.session.generation,
        owner_instance_id: state.session.owner_instance_id,
        baseline: state.state.sequence,
        limits: Keyword.get(opts, :delivery_limits, %{}),
        token_secret: Keyword.get(opts, :token_secret, :crypto.strong_rand_bytes(32))
      )

    identity = delivery_identity(state.session, client.id, attachment.id)

    with {:ok, snapshot} <- Recovery.attach_snapshot(state.state, identity) do
      record = %{
        identity: client,
        attachment: attachment,
        pid: pid,
        ref: Process.monitor(pid),
        timer_ref: nil,
        delivery: delivery
      }

      {previous, clients} = Map.pop(state.clients, client.id)
      if previous, do: cleanup_client(previous)
      state = %{state | clients: Map.put(clients, client.id, record)}

      {:ok, state, %{attachment: attachment, snapshot: snapshot}}
    end
  end

  defp handle_output_pull(state, client_id, client, identity) do
    case Delivery.pull(client.delivery, identity) do
      {:ok, delivery, batch} ->
        client =
          client
          |> cancel_delivery_timer()
          |> put_delivery(delivery)
          |> schedule_delivery_timer()

        {:reply, {:ok, batch}, put_client(state, client_id, client)}

      {:gap, delivery, gap} ->
        client = client |> cancel_delivery_timer() |> put_delivery(delivery)
        {:reply, {:gap, gap}, put_client(state, client_id, client)}

      {:empty, delivery} ->
        {:reply, :empty, put_client(state, client_id, put_delivery(client, delivery))}

      {:error, reason, delivery} ->
        {:reply, {:error, reason}, put_client(state, client_id, put_delivery(client, delivery))}
    end
  end

  defp handle_output_ack(state, client_id, client, identity, token) do
    case Delivery.ack(client.delivery, identity, token) do
      {:ok, delivery, receipt, advisory?} ->
        client = client |> cancel_delivery_timer() |> put_delivery(delivery)
        if advisory?, do: send_ready(client)
        {:reply, {:ok, receipt}, put_client(state, client_id, client)}

      {:error, reason, delivery} ->
        {:reply, {:error, reason}, put_client(state, client_id, put_delivery(client, delivery))}
    end
  end

  defp timeout_client(%{attachment: %{id: attachment_id}} = client, attachment_id, timer_token, sequence) do
    case Delivery.timeout(client.delivery, attachment_id, timer_token, sequence) do
      {:gap, delivery, _gap, advisory?} ->
        client = client |> cancel_delivery_timer() |> put_delivery(delivery)
        if advisory?, do: send_ready(client)
        client

      {:ok, delivery} ->
        put_delivery(client, delivery)
    end
  end

  defp timeout_client(client, _attachment_id, _timer_token, _sequence), do: client

  defp delivery_identity(%{kind: :session} = session, client_id, attachment_id),
    do: %{
      session_id: session.id,
      client_id: client_id,
      attachment_id: attachment_id,
      generation: session.generation,
      owner_instance_id: session.owner_instance_id
    }

  defp delivery_identity(session_id, client_id, attachment_id),
    do: %{session_id: session_id, client_id: client_id, attachment_id: attachment_id}

  defp attachment_identity(session, opts) do
    identity_opts = [
      session_id: session.id,
      generation: session.generation,
      owner_instance_id: session.owner_instance_id
    ]

    case Keyword.get(opts, :attachment_id) do
      nil -> Identity.new!(:attachment, identity_opts)
      id -> Identity.new!(:attachment, Keyword.put(identity_opts, :id, id))
    end
  end

  defp send_ready(client) do
    advisory = Delivery.advisory(client.delivery)

    if :erlang.external_size(advisory) <= client.delivery.limits.advisory_bytes do
      send(client.pid, advisory)
    end

    :ok
  end

  defp schedule_delivery_timer(client) do
    inflight = client.delivery.inflight

    timer_ref =
      Process.send_after(
        self(),
        {:delivery_ack_timeout, fence_token(client.identity), client.attachment.id, inflight.timer_token},
        client.delivery.limits.ack_timeout_ms
      )

    %{client | timer_ref: timer_ref}
  end

  defp cancel_delivery_timer(%{timer_ref: nil} = client), do: client

  defp cancel_delivery_timer(client) do
    Process.cancel_timer(client.timer_ref)
    %{client | timer_ref: nil}
  end

  defp cleanup_client(client) do
    client = cancel_delivery_timer(client)
    Process.demonitor(client.ref, [:flush])
    Delivery.detach(client.delivery)
    :ok
  end

  defp put_delivery(client, delivery), do: %{client | delivery: delivery}
  defp put_client(state, client_id, client), do: %{state | clients: Map.put(state.clients, client_id, client)}

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

  defp fence_token(%{session: session}), do: fence_token(session)

  defp fence_token(identity),
    do: {identity.generation, identity.owner_instance_id}

  defp current_fence_token?(state, token), do: fence_token(state) == token

  defp generation_relay(owner, fence) do
    receive do
      :stop_generation_relay ->
        :ok

      message ->
        send(owner, {:generation_message, fence, message})
        generation_relay(owner, fence)
    end
  end

  defp stop_generation_relay(%{relay: relay}) when is_pid(relay) do
    send(relay, :stop_generation_relay)
    :ok
  end

  defp stop_generation_relay(_active), do: :ok

  defp generation_options(opts) do
    opts
    |> Keyword.take([:writer, :quota, :admission, :deadline, :jidoka_lease_id])
    |> maybe_put_option(:expected_generation, Keyword.get(opts, :expected_generation))
    |> maybe_put_option(:owner_instance_id, Keyword.get(opts, :owner_instance_id))
    |> maybe_put_option(:operation_id, Keyword.get(opts, :generation_operation_id))
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp bounded_append(items, item), do: Enum.take(items ++ [item], -@completed_limit)
  defp bounded_text(nil), do: nil
  defp bounded_text(text) when is_binary(text), do: String.slice(text, 0, 200_000)
  defp bounded_text(value), do: value |> inspect(limit: 20) |> String.slice(0, 4_096)
  defp portable_reason(nil), do: nil
  defp portable_reason(reason), do: reason |> Jido.Console.Error.message() |> String.slice(0, 4_096)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
