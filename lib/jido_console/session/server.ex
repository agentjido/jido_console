defmodule Jido.Console.Session.Server do
  @moduledoc """
  Process owner for one live semantic session.

  The server is the only owner of history, active runs, queues, controls, and
  Console event order. Clients attach and detach without becoming a second
  owner. Model and tool work is delegated outside this process.
  """

  use GenServer, restart: :temporary

  alias Jido.Console.Session.{
    Delivery,
    DynamicSupervisor,
    Identity,
    Identity.Admission,
    Input,
    Reducer,
    Registry,
    State
  }

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

  @doc "Attaches a client to the session."
  @spec attach(name(), Identity.t()) :: {:ok, map()} | {:error, term()}
  def attach(server, client), do: GenServer.call(server, {:attach, client, self()})

  @doc "Detaches a client without stopping the session."
  @spec detach(name(), Identity.t()) :: :ok | {:error, term()}
  def detach(server, client), do: GenServer.call(server, {:detach, client})

  @doc "Returns the current semantic state."
  @spec state(name()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

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

  @doc "Replaces one attached client's delivery state after recovery."
  @spec put_delivery(name(), String.t(), Delivery.t()) :: {:ok, Delivery.t()} | {:error, term()}
  def put_delivery(server, client_id, delivery) do
    GenServer.call(server, {:put_delivery, client_id, delivery})
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
       reserved: 0
     }}
  end

  @impl true
  def handle_call({:attach, client, pid}, _from, state) do
    if client.session_id != state.session.id do
      {:reply, {:error, :cross_session_result}, state}
    else
      ref = Process.monitor(pid)

      record = %{
        identity: client,
        pid: pid,
        ref: ref,
        delivery: Delivery.new(client_id: client.id, session_id: state.session.id)
      }

      clients = Map.put(state.clients, client.id, record)
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

  def handle_call(:next_sequence, _from, state) do
    next = max(state.reserved, state.state.sequence) + 1
    {:reply, next, %{state | reserved: next}}
  end

  def handle_call({:admit_event, event}, _from, state) do
    case Reducer.apply_event(state.state, event) do
      {:ok, next} ->
        clients = publish(state.clients, next)
        {:reply, {:ok, next}, %{state | state: next, clients: clients}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:admit_input, input}, _from, state) do
    if input.identity.session_id != state.session.id do
      {:reply, {:error, :cross_session_result}, state}
    else
      {:reply, {:ok, input}, %{state | inputs: state.inputs ++ [input]}}
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

  def handle_call({:put_delivery, client_id, delivery}, _from, state) do
    case Map.fetch(state.clients, client_id) do
      :error ->
        {:reply, {:error, :not_attached}, state}

      {:ok, client} ->
        if delivery.client_id == client_id and delivery.session_id == state.session.id do
          clients = Map.put(state.clients, client_id, %{client | delivery: delivery})
          {:reply, {:ok, delivery}, %{state | clients: clients}}
        else
          {:reply, {:error, :identity_mismatch}, state}
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
               results: state.results ++ [result]
           }}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    clients =
      state.clients
      |> Enum.reject(fn {_id, client} -> client.ref == ref end)
      |> Map.new()

    {:noreply, %{state | clients: clients}}
  end

  defp publish(clients, session_state) do
    update =
      session_state
      |> Reducer.snapshot()
      |> Map.put("coalesce", true)

    Map.new(clients, fn {id, client} ->
      {id, deliver(client, session_state.session_id, update)}
    end)
  end

  defp deliver(client, session_id, update) do
    case Delivery.offer(client.delivery, update) do
      {:ok, delivery, payload} ->
        send(client.pid, {:session_updated, session_id, payload})
        %{client | delivery: delivery}

      {:gap, delivery, gap} ->
        send(client.pid, {:session_gap, session_id, gap})
        %{client | delivery: delivery}
    end
  end
end
