defmodule Jido.Console.Process.Supervisor do
  @moduledoc """
  Owns registered local background processes and their shutdown path.

  The supervisor tracks live owners, writes home markers, and stops the exact
  owned set on command, owner exit, or its own termination.
  """

  use GenServer

  alias Jido.Console.Process.{Contract, Store}

  @typedoc "Supervisor start options, including Jido home overrides."
  @type start_opt :: {:name, atom()} | {atom(), term()}

  @doc "Starts the process supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers an owned process and marks it ready."
  @spec register(Contract.kind(), pid(), keyword()) :: {:ok, Contract.process_record()} | {:error, term()}
  def register(kind, pid, opts \\ []) do
    call(opts, {:register, kind, pid, opts})
  end

  @doc "Stops one named process through its owner."
  @spec stop_named(String.t(), keyword()) :: {:ok, Contract.process_record()} | {:error, term()}
  def stop_named(name, opts \\ []) do
    call(opts, {:stop, name})
  end

  @doc "Stops every owned process."
  @spec stop_all(keyword()) :: {:ok, [Contract.process_record()]} | {:error, term()}
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
    identity = Contract.identity(kind)

    case validate_requested_identity(identity, register_opts) do
      :ok ->
        case Map.get(state.processes, identity) do
          %{record: %{owner_pid: owner}} when is_pid(owner) ->
            if Elixir.Process.alive?(owner) do
              {:reply, {:error, :process_already_registered}, state}
            else
              do_register(kind, pid, identity, state)
            end

          _other ->
            do_register(kind, pid, identity, state)
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stop, name}, {caller, _tag}, state) do
    {reply, state} =
      case Contract.identity_for_name(name) do
        {:ok, identity} -> stop_one(state, identity, caller)
        {:error, _reason} = error -> {error, state}
      end

    {:reply, reply, state}
  end

  def handle_call(:stop_all, {caller, _tag}, state) do
    {records, state} =
      state.processes
      |> Map.keys()
      |> Enum.reduce({[], state}, fn identity, {acc, state} ->
        case stop_one(state, identity, caller) do
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
      {identity, entry} ->
        status = if reason == :normal, do: :stopped, else: :failed
        _ = finalize(entry.record, status, failure_text(reason), state.opts)
        {:noreply, %{state | processes: Map.delete(state.processes, identity)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, state) do
    Enum.each(state.processes, fn {_id, entry} ->
      stop_owner(entry.record)
      _ = finalize(entry.record, :stopped, nil, state.opts)
    end)

    _ = Store.reap(state.opts)
    :ok
  end

  defp call(opts, message) do
    opts
    |> Keyword.get(:name, __MODULE__)
    |> GenServer.call(message)
  end

  defp stop_one(state, identity, caller) do
    case Map.pop(state.processes, identity) do
      {%{record: record, monitor: mon}, processes} ->
        Elixir.Process.demonitor(mon, [:flush])
        stop_owner(record, caller)
        {:ok, stopped} = finalize(record, :stopped, nil, state.opts)
        {{:ok, Contract.public(stopped)}, %{state | processes: processes}}

      {nil, _processes} ->
        case Store.get(identity, state.opts) do
          {:ok, record} ->
            {:ok, stopped} = finalize(record, :stopped, nil, state.opts)
            {{:ok, Contract.public(stopped)}, state}

          {:error, :process_not_found} ->
            {{:ok, already_stopped(identity)}, state}

          {:error, _reason} = error ->
            {error, state}
        end
    end
  end

  defp finalize(record, status, failure, opts) do
    updated = %{record | status: status, failure: failure, readiness: readiness_for(status, record)}

    result =
      if status in [:stopped, :failed] do
        with :ok <- Store.delete(Contract.key(record), opts), do: {:ok, updated}
      else
        Store.put(updated, opts)
      end

    result
  end

  defp readiness_for(:stopped, _record), do: "stopped"
  defp readiness_for(:failed, _record), do: "failed"

  defp already_stopped({kind, name}) do
    spec = Contract.spec(kind)

    %{
      kind: kind,
      name: name,
      owner: spec.owner,
      status: :stopped,
      readiness: "already stopped",
      failure: nil
    }
  end

  defp stopped_record(record), do: Contract.public(%{record | status: :stopped, readiness: "stopped"})

  defp do_register(kind, pid, identity, state) do
    record = Contract.live(kind, pid, beam_os_pid())

    mon = Elixir.Process.monitor(pid)

    case Store.put(record, state.opts) do
      {:ok, stored} ->
        public = Contract.public(stored)

        {:reply, {:ok, public},
         %{state | processes: Map.put(state.processes, identity, %{record: stored, monitor: mon})}}

      {:error, _reason} = error ->
        Elixir.Process.demonitor(mon, [:flush])
        {:reply, error, state}
    end
  end

  defp stop_owner(%{owner_pid: pid}) when is_pid(pid) do
    if Elixir.Process.alive?(pid), do: Elixir.Process.exit(pid, :shutdown)
    :ok
  end

  defp stop_owner(%{owner_os_pid: os_pid}) when is_integer(os_pid) and os_pid > 1 do
    _ = Jido.Console.Process.Tree.stop(os_pid)
    :ok
  end

  defp stop_owner(_record), do: :ok

  defp stop_owner(%{owner_pid: caller}, caller), do: :ok
  defp stop_owner(record, _caller), do: stop_owner(record)

  defp beam_os_pid do
    case Integer.parse(System.pid()) do
      {pid, ""} when pid > 1 -> pid
      _invalid -> nil
    end
  end

  defp failure_text(:normal), do: nil
  defp failure_text(reason), do: inspect(reason)

  defp validate_requested_identity(identity, opts) do
    expected = Contract.name(identity)

    case Keyword.fetch(opts, :id) do
      :error ->
        :ok

      {:ok, ^expected} ->
        :ok

      {:ok, requested} ->
        {:error, {:process_identity_conflict, expected, requested}}
    end
  end
end
