defmodule Jido.Console.Session.Server do
  @moduledoc "One temporary OTP owner for one Console thread."

  use GenServer

  alias Jido.Console.Session.{BindingRequest, Command, Registry, Thread, View}

  @type name :: GenServer.server()

  @doc "Returns a temporary child specification."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :thread_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Starts one registered thread owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    registry = Keyword.get(opts, :registry, Registry)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(thread_id, registry))
  end

  @doc "Returns the existing owner or starts exactly one lazy owner."
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(thread_id, opts \\ []) when is_binary(thread_id) and thread_id != "" do
    registry = Keyword.get(opts, :registry, Registry)

    case Registry.lookup(thread_id, registry) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> start_lazy(thread_id, opts, registry)
    end
  end

  @doc "Runs one validated thread command."
  @spec command(name(), Command.t()) :: :ok | {:ok, term()} | {:error, term()}
  def command(server, %Command{} = command), do: command(server, command, 5_000)

  @doc "Runs one direct command with a timeout, or one command for an exact attachment."
  @spec command(name(), Command.t(), timeout()) :: :ok | {:ok, term()} | {:error, term()}
  @spec command(name(), reference(), Command.t()) :: :ok | {:ok, term()} | {:error, term()}
  def command(server, command_or_attachment, timeout_or_command)

  def command(server, %Command{} = command, timeout),
    do: GenServer.call(server, {:command, command}, timeout)

  def command(server, attachment_ref, %Command{} = command),
    do: command(server, attachment_ref, command, 5_000)

  @doc "Runs one command for an exact attachment with a timeout."
  @spec command(name(), reference(), Command.t(), timeout()) ::
          :ok | {:ok, term()} | {:error, term()}
  def command(server, attachment_ref, %Command{} = command, timeout)
      when is_reference(attachment_ref),
      do: GenServer.call(server, {:attached_command, attachment_ref, command}, timeout)

  @doc "Attaches a subscriber and atomically returns its complete current View."
  @spec attach(name(), pid()) :: {:ok, %{attachment_ref: reference(), view: View.t()}}
  def attach(server, subscriber \\ self()) when is_pid(subscriber),
    do:
      attach(server, subscriber, %BindingRequest{
        agent_source: nil,
        coding_pack: nil,
        model: nil,
        execution_policy: nil,
        project_root: nil
      })

  @doc "Attaches with explicit binding choices for owner-side conflict checks."
  @spec attach(name(), pid(), BindingRequest.t()) ::
          {:ok, %{attachment_ref: reference(), view: View.t()}} | {:error, term()}
  def attach(server, subscriber, %BindingRequest{} = request) when is_pid(subscriber),
    do: GenServer.call(server, {:attach, subscriber, request})

  @doc "Detaches one exact private attachment."
  @spec detach(name(), reference()) :: :ok
  def detach(server, attachment_ref) when is_reference(attachment_ref),
    do: GenServer.call(server, {:detach, attachment_ref})

  @doc "Returns the complete current View without attaching."
  @spec view(name()) :: View.t()
  def view(server), do: GenServer.call(server, :view)

  @doc "Stops an idle owner."
  @spec stop(name()) :: :ok | {:error, term()}
  def stop(server), do: GenServer.call(server, :stop)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Thread.init(opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:attach, subscriber}, from, state) do
    handle_call(
      {:attach, subscriber,
       %BindingRequest{
         agent_source: nil,
         coding_pack: nil,
         model: nil,
         execution_policy: nil,
         project_root: nil
       }},
      from,
      state
    )
  end

  def handle_call({:attach, subscriber, request}, _from, state) do
    case Thread.attach_request(state, request) do
      :ok ->
        {attachment_ref, view, state} = View.attach(state, subscriber)
        {:reply, {:ok, %{attachment_ref: attachment_ref, view: view}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, attachment_ref}, _from, state),
    do: {:reply, :ok, View.detach(state, attachment_ref)}

  def handle_call(:view, _from, state), do: {:reply, View.from_thread(state), state}

  def handle_call(:stop, _from, %{status: :idle, active: nil} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(:stop, _from, %{status: :reconciling} = state),
    do: {:reply, {:error, :thread_reconciling}, state}

  def handle_call(:stop, _from, state), do: {:reply, {:error, :thread_busy}, state}

  def handle_call({:attached_command, attachment_ref, command}, from, state) do
    if Map.has_key?(state.subscribers, attachment_ref),
      do: handle_call({:command, command}, from, state),
      else: {:reply, {:error, :not_attached}, state}
  end

  def handle_call({:command, %Command{thread_id: thread_id}}, _from, %{thread_id: current} = state)
      when thread_id != current,
      do: {:reply, {:error, :cross_thread_command}, state}

  def handle_call({:command, %Command{type: :stop}}, from, state),
    do: handle_call(:stop, from, state)

  def handle_call({:command, command}, _from, %{status: :reconciling} = state) do
    case Thread.reconcile(state) do
      {:ok, %{status: :idle} = state} -> Thread.command(command, state)
      {:ok, state} -> {:reply, {:error, :thread_reconciling}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, Thread.unavailable(state, reason)}
    end
  end

  def handle_call({:command, command}, _from, state), do: Thread.command(command, state)

  @impl true
  def handle_info(:start_active, %{status: :idle, active: active} = state) when not is_nil(active),
    do: {:noreply, Thread.start_active(state)}

  def handle_info(:start_active, state), do: {:noreply, state}

  def handle_info({:bridge_linked, pid, run_ref}, state),
    do: {:noreply, Thread.bridge_linked(state, pid, run_ref)}

  def handle_info({:bridge_handle, pid, run_ref, request_id, handle}, state),
    do: {:noreply, Thread.bridge_handle(state, pid, run_ref, request_id, handle)}

  def handle_info({:bridge_event, run_ref, request_id, event}, state),
    do: {:noreply, Thread.bridge_event(state, run_ref, request_id, event)}

  def handle_info({:publish_partial, run_ref, token}, state),
    do: {:noreply, Thread.publish_partial(state, run_ref, token)}

  def handle_info({:bridge_result, pid, run_ref, request_id, result}, state),
    do: {:noreply, Thread.bridge_result(state, pid, run_ref, request_id, result)}

  def handle_info({:EXIT, pid, :normal}, state) do
    cond do
      Thread.bridge_pid?(state, pid) -> {:stop, {:bridge_result_missing, pid}, state}
      Thread.resource_pid?(state, pid) -> {:stop, {:thread_resource_failed, :normal}, state}
      true -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      Thread.bridge_pid?(state, pid) -> {:stop, {:bridge_exit, reason}, state}
      Thread.resource_pid?(state, pid) -> {:stop, {:thread_resource_failed, reason}, state}
      true -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    if Thread.resource_monitor?(state, monitor, pid),
      do: {:stop, {:thread_resource_failed, reason}, state},
      else: {:noreply, View.subscriber_down(state, monitor)}
  end

  def handle_info(:reconcile, state) do
    case Thread.reconcile(%{state | wake_ref: nil}) do
      {:ok, state} -> {:noreply, View.publish(state)}
      {:error, reason, state} -> {:stop, {:reconciliation_failed, reason}, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Thread.close(state)
    :ok
  end

  defp start_lazy(thread_id, opts, registry) do
    opts = Keyword.put(opts, :thread_id, thread_id)

    case Jido.Console.Session.DynamicSupervisor.start_session(__MODULE__, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:already_present, _id}} ->
        Registry.lookup(thread_id, registry)

      {:error, reason} ->
        case Registry.lookup(thread_id, registry) do
          {:ok, pid} -> {:ok, pid}
          {:error, :not_found} -> {:error, reason}
        end
    end
  end
end
