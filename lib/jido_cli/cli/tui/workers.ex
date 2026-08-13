defmodule Jido.Cli.Tui.Workers do
  @moduledoc false

  @relay_flush_timeout_ms 1_000

  defmodule Worker do
    @moduledoc false
    @enforce_keys [:pid, :ref, :kind, :subject]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            pid: pid(),
            ref: reference(),
            kind: term(),
            subject: term()
          }
  end

  @type t :: %{optional(pid()) => Worker.t()}

  @spec start(t(), term(), term(), (-> term())) :: t()
  def start(workers, kind, subject, fun) when is_map(workers) and is_function(fun, 0) do
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(owner, {:jido_tui_effect_result, self(), safe_effect(fun)})
      end)

    put(workers, pid, ref, kind, subject)
  end

  @spec start_turn(t(), (pid() -> term())) :: t()
  def start_turn(workers, fun) when is_map(workers) and is_function(fun, 1) do
    {workers, relay_pid} = start_relay(workers, nil, true)

    workers
    |> start({:start_turn, relay_pid}, nil, fn -> fun.(relay_pid) end)
  end

  @spec start_review(t(), :approve | :deny, term(), (pid() -> term())) :: t()
  def start_review(workers, decision, subject, fun)
      when is_map(workers) and decision in [:approve, :deny] and is_function(fun, 1) do
    {workers, relay_pid} = start_relay(workers, subject, false)
    workers = activate_relay(workers, relay_pid, subject)
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        outcome = safe_effect(fn -> fun.(relay_pid) end)
        flush_relay(relay_pid)
        send(owner, {:jido_tui_effect_result, self(), outcome})
      end)

    put(workers, pid, ref, {:respond_review, decision, relay_pid}, subject)
  end

  @spec pop(t(), pid()) :: {:ok, Worker.t(), t()} | :error
  def pop(workers, pid) do
    case Map.pop(workers, pid) do
      {nil, _workers} ->
        :error

      {worker, workers} ->
        Process.demonitor(worker.ref, [:flush])
        {:ok, worker, workers}
    end
  end

  @spec take_down(t(), pid(), reference()) :: {:ok, Worker.t(), t()} | :error
  def take_down(workers, pid, ref) do
    case Map.get(workers, pid) do
      %Worker{ref: ^ref} = worker -> {:ok, worker, Map.delete(workers, pid)}
      _other -> :error
    end
  end

  @spec activate_relay(t(), pid(), term()) :: t()
  def activate_relay(workers, relay_pid, request) do
    case Map.fetch(workers, relay_pid) do
      {:ok, %Worker{} = relay} ->
        send(relay_pid, :activate)
        Map.put(workers, relay_pid, %{relay | subject: request})

      :error ->
        workers
    end
  end

  @spec stop_subject(t(), term()) :: t()
  def stop_subject(workers, subject) do
    workers
    |> Enum.filter(fn {_pid, worker} -> worker.subject == subject end)
    |> Enum.reduce(workers, fn {pid, _worker}, workers -> stop(workers, pid) end)
  end

  @spec stop(t(), pid()) :: t()
  def stop(workers, pid) do
    case Map.pop(workers, pid) do
      {nil, workers} ->
        workers

      {worker, workers} ->
        Process.demonitor(worker.ref, [:flush])
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        workers
    end
  end

  @spec stop_all(t()) :: :ok
  def stop_all(workers) do
    Enum.each(workers, fn {pid, worker} ->
      Process.demonitor(worker.ref, [:flush])
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  defp put(workers, pid, ref, kind, subject) do
    Map.put(workers, pid, %Worker{pid: pid, ref: ref, kind: kind, subject: subject})
  end

  defp start_relay(workers, subject, stop_on_terminal?) do
    owner = self()
    {relay_pid, relay_ref} = spawn_monitor(fn -> stream_relay(owner, stop_on_terminal?) end)
    {put(workers, relay_pid, relay_ref, :stream_relay, subject), relay_pid}
  end

  defp safe_effect(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:crash, exception}
  catch
    kind, reason -> {:crash, {kind, reason}}
  end

  defp flush_relay(relay_pid) do
    send(relay_pid, {:flush, self()})

    receive do
      {:relay_flushed, ^relay_pid} -> :ok
    after
      @relay_flush_timeout_ms -> :ok
    end
  end

  defp stream_relay(owner, stop_on_terminal?) do
    owner_ref = Process.monitor(owner)
    stream_relay(owner, owner_ref, stop_on_terminal?, :buffering, [])
  end

  defp stream_relay(owner, owner_ref, stop_on_terminal?, :buffering, buffered) do
    receive do
      {:jidoka_turn_event, event} ->
        stream_relay(owner, owner_ref, stop_on_terminal?, :buffering, [event | buffered])

      :activate ->
        events = Enum.reverse(buffered)
        Enum.each(events, &send(owner, {:jidoka_turn_event, &1}))

        if stop_on_terminal? and Enum.any?(events, &terminal_event?/1) do
          :ok
        else
          stream_relay(owner, owner_ref, stop_on_terminal?, :active, [])
        end

      {:flush, caller} ->
        send(caller, {:relay_flushed, self()})
        stream_relay(owner, owner_ref, stop_on_terminal?, :buffering, buffered)

      :stop ->
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      _message ->
        stream_relay(owner, owner_ref, stop_on_terminal?, :buffering, buffered)
    end
  end

  defp stream_relay(owner, owner_ref, stop_on_terminal?, :active, []) do
    receive do
      {:jidoka_turn_event, event} ->
        send(owner, {:jidoka_turn_event, event})

        if stop_on_terminal? and terminal_event?(event),
          do: :ok,
          else: stream_relay(owner, owner_ref, stop_on_terminal?, :active, [])

      {:flush, caller} ->
        send(caller, {:relay_flushed, self()})
        stream_relay(owner, owner_ref, stop_on_terminal?, :active, [])

      :stop ->
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      _message ->
        stream_relay(owner, owner_ref, stop_on_terminal?, :active, [])
    end
  end

  defp terminal_event?(event) do
    Jidoka.Stream.terminal?(event)
  rescue
    _exception -> false
  end
end
