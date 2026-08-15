defmodule Jido.Console.Process.Supervisor do
  @moduledoc """
  Owns registered local background processes and their shutdown path.

  The supervisor tracks live owners, writes home markers, and stops the exact
  owned set on command, owner exit, or its own termination.
  """

  use GenServer

  alias Jido.Console.Process
  alias Jido.Console.Process.Store

  @typedoc "Supervisor start options, including Jido home overrides."
  @type start_opt :: {:name, atom()} | {atom(), term()}

  @doc "Starts the process supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts the supervisor if it is not already running.

  The server is parented by a keeper process so a short-lived caller such as
  the TUI can exit without taking the named registry down.
  """
  @spec ensure_started(keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Elixir.Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_detached(name, opts)
    end
  end

  @doc "Registers an owned process and marks it ready."
  @spec register(Process.kind(), pid(), keyword()) :: {:ok, Process.process_record()} | {:error, term()}
  def register(kind, pid, opts \\ []) do
    call(opts, {:register, kind, pid, opts})
  end

  @doc "Stops one named process through its owner."
  @spec stop_named(String.t(), keyword()) :: {:ok, Process.process_record()} | {:error, term()}
  def stop_named(name, opts \\ []) do
    call(opts, {:stop, name})
  end

  @doc "Stops every owned process."
  @spec stop_all(keyword()) :: {:ok, [Process.process_record()]} | {:error, term()}
  def stop_all(opts \\ []) do
    call(opts, :stop_all)
  end

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    Elixir.Process.flag(:trap_exit, true)
    {:ok, reaped} = Store.reap(opts)
    {:ok, %{opts: opts, processes: %{}, reaped: reaped}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call({:register, kind, pid, register_opts}, _from, state) do
    spec = Process.spec(kind)

    record = %{
      id: Keyword.get(register_opts, :id, spec.name),
      kind: kind,
      name: spec.name,
      owner: spec.owner,
      status: :ready,
      readiness: spec.readiness,
      failure: nil,
      owner_pid: pid
    }

    mon = Elixir.Process.monitor(pid)

    case Store.put(record, state.opts) do
      {:ok, stored} ->
        public = public_record(stored)

        {:reply, {:ok, public},
         %{state | processes: Map.put(state.processes, record.id, %{record: stored, monitor: mon})}}

      {:error, _reason} = error ->
        Elixir.Process.demonitor(mon, [:flush])
        {:reply, error, state}
    end
  end

  def handle_call({:stop, name}, _from, state) do
    {reply, state} = stop_one(state, name)
    {:reply, reply, state}
  end

  def handle_call(:stop_all, _from, state) do
    {records, state} =
      state.processes
      |> Map.keys()
      |> Enum.reduce({[], state}, fn id, {acc, state} ->
        case stop_one(state, id) do
          {{:ok, record}, state} -> {[record | acc], state}
          {{:error, _reason}, state} -> {acc, state}
        end
      end)

    {:ok, stale} = Store.reap(state.opts)
    {:reply, {:ok, Enum.reverse(records) ++ Enum.map(stale, &stopped_record/1)}, state}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, mon, :process, pid, reason}, state) do
    case Enum.find(state.processes, fn {_id, entry} -> entry.monitor == mon or entry.record.owner_pid == pid end) do
      {id, entry} ->
        status = if reason == :normal, do: :stopped, else: :failed
        _ = finalize(entry.record, status, failure_text(reason), state.opts)
        {:noreply, %{state | processes: Map.delete(state.processes, id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, state) do
    Enum.each(state.processes, fn {_id, entry} ->
      stop_owner(entry.record.owner_pid)
      _ = finalize(entry.record, :stopped, nil, state.opts)
    end)

    _ = Store.reap(state.opts)
    :ok
  end

  defp call(opts, message) do
    with {:ok, pid} <- ensure_started(opts) do
      call_server(pid, message, opts)
    end
  end

  defp call_server(pid, message, opts) do
    GenServer.call(pid, message)
  catch
    :exit, reason ->
      if retryable_call_exit?(reason) do
        retry_call(opts, message)
      else
        exit(reason)
      end
  end

  defp retry_call(opts, message) do
    Elixir.Process.sleep(10)

    with {:ok, pid} <- ensure_started(opts) do
      GenServer.call(pid, message)
    end
  end

  defp retryable_call_exit?(:noproc), do: true
  defp retryable_call_exit?(:normal), do: true
  defp retryable_call_exit?(:shutdown), do: true
  defp retryable_call_exit?({reason, _info}) when reason in [:noproc, :normal, :shutdown], do: true
  defp retryable_call_exit?(_reason), do: false

  defp start_detached(name, opts) do
    starter = self()
    ref = make_ref()

    keeper =
      spawn(fn ->
        Elixir.Process.flag(:trap_exit, true)

        result =
          case GenServer.start_link(__MODULE__, opts, name: name) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            other -> other
          end

        send(starter, {ref, result})
        keep_parent(result)
      end)

    receive do
      {^ref, result} -> result
    after
      5_000 ->
        Elixir.Process.exit(keeper, :kill)
        {:error, :process_supervisor_start_timeout}
    end
  end

  defp keep_parent({:ok, pid}) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    end
  end

  defp keep_parent(_result), do: :ok

  defp stop_one(state, name) do
    case Map.pop(state.processes, name) do
      {%{record: record, monitor: mon}, processes} ->
        Elixir.Process.demonitor(mon, [:flush])
        stop_owner(record.owner_pid)
        {:ok, stopped} = finalize(record, :stopped, nil, state.opts)
        {{:ok, public_record(stopped)}, %{state | processes: processes}}

      {nil, _processes} ->
        case Store.get(name, state.opts) do
          {:ok, record} ->
            {:ok, stopped} = finalize(record, :stopped, nil, state.opts)
            {{:ok, public_record(stopped)}, state}

          {:error, :process_not_found} ->
            {{:ok, already_stopped(name)}, state}

          {:error, _reason} = error ->
            {error, state}
        end
    end
  end

  defp finalize(record, status, failure, opts) do
    updated = %{record | status: status, failure: failure, readiness: readiness_for(status, record)}

    result =
      if status in [:stopped, :failed] do
        with :ok <- Store.delete(record.id, opts), do: {:ok, updated}
      else
        Store.put(updated, opts)
      end

    result
  end

  defp readiness_for(:stopped, _record), do: "stopped"
  defp readiness_for(:failed, _record), do: "failed"

  defp already_stopped(name) do
    spec =
      Enum.find_value(Process.catalog(), fn {_kind, spec} ->
        if spec.name == name, do: spec
      end) || %{name: name, owner: "unknown", readiness: "stopped"}

    %{
      id: name,
      kind: :interactive,
      name: spec.name,
      owner: spec.owner,
      status: :stopped,
      readiness: "already stopped",
      failure: nil
    }
  end

  defp stopped_record(record), do: public_record(%{record | status: :stopped, readiness: "stopped"})

  defp stop_owner(pid) when is_pid(pid) do
    if Elixir.Process.alive?(pid) do
      Elixir.Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp stop_owner(_pid), do: :ok

  defp failure_text(:normal), do: nil
  defp failure_text(reason), do: inspect(reason)

  defp public_record(record) do
    Map.take(record, [:id, :kind, :name, :owner, :status, :readiness, :failure])
  end
end
