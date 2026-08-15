defmodule Jido.Console.Tui.Workers do
  @moduledoc false

  @relay_flush_timeout_ms 1_000
  @shutdown_timeout_ms 250

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
      spawn_link_monitor(fn ->
        send(owner, {:jido_tui_effect_result, self(), safe_effect(fun)})
      end)

    put(workers, pid, ref, kind, subject)
  end

  @spec start_turn(t(), (pid() -> term())) :: t()
  def start_turn(workers, fun) when is_map(workers) and is_function(fun, 1) do
    {workers, relay_pid} = start_relay(workers, nil, true)
    owner = self()

    {pid, ref} =
      spawn_link_monitor(fn ->
        owner_ref = Process.monitor(owner)
        send(owner, {:jido_tui_effect_result, self(), safe_effect(fn -> fun.(relay_pid) end)})
        await_release(owner, owner_ref)
      end)

    put(workers, pid, ref, {:start_turn, relay_pid}, nil)
  end

  @spec start_review(t(), :approve | :deny, term(), (pid() -> term())) :: t()
  def start_review(workers, decision, subject, fun)
      when is_map(workers) and decision in [:approve, :deny] and is_function(fun, 1) do
    {workers, relay_pid} = start_relay(workers, subject, false)
    workers = activate_relay(workers, relay_pid, subject)
    owner = self()

    {pid, ref} =
      spawn_link_monitor(fn ->
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

  @spec take_completion(t(), pid()) :: {:ok, Worker.t(), t()} | :error
  def take_completion(workers, pid) do
    case Map.get(workers, pid) do
      %Worker{kind: {:start_turn, _relay_pid}} = worker -> {:ok, worker, workers}
      %Worker{} -> pop(workers, pid)
      nil -> :error
    end
  end

  @spec promote_request_owner(t(), pid(), term()) :: t()
  def promote_request_owner(workers, pid, request) do
    case Map.get(workers, pid) do
      %Worker{kind: {:start_turn, _relay_pid}} = worker ->
        Map.put(workers, pid, %{worker | kind: :request_owner, subject: request})

      _worker ->
        workers
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

        if Process.alive?(pid) do
          Process.unlink(pid)
          Process.exit(pid, :kill)
        end

        workers
    end
  end

  @spec stop_all(t(), non_neg_integer()) :: :ok
  def stop_all(workers, timeout_ms \\ @shutdown_timeout_ms)
      when is_map(workers) and is_integer(timeout_ms) and timeout_ms >= 0 do
    Enum.each(workers, fn {pid, _worker} ->
      if Process.alive?(pid) do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end)

    await_stopped(workers, deadline(timeout_ms))
  end

  @spec reap(pid(), non_neg_integer()) :: :ok
  def reap(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) and timeout_ms >= 0 do
    Process.unlink(pid)

    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        timeout_ms -> Process.demonitor(ref, [:flush])
      end
    end

    :ok
  end

  defp put(workers, pid, ref, kind, subject) do
    Map.put(workers, pid, %Worker{pid: pid, ref: ref, kind: kind, subject: subject})
  end

  defp start_relay(workers, subject, stop_on_terminal?) do
    owner = self()
    {relay_pid, relay_ref} = spawn_link_monitor(fn -> stream_relay(owner, stop_on_terminal?) end)
    {put(workers, relay_pid, relay_ref, :stream_relay, subject), relay_pid}
  end

  defp spawn_link_monitor(fun), do: :erlang.spawn_opt(fun, [:link, :monitor])

  defp await_release(owner, owner_ref) do
    receive do
      :stop -> :ok
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
      _message -> await_release(owner, owner_ref)
    end
  end

  defp await_stopped(workers, _deadline) when map_size(workers) == 0, do: :ok

  defp await_stopped(workers, deadline) do
    remaining = remaining_ms(deadline)

    receive do
      {:DOWN, ref, :process, pid, _reason} ->
        workers =
          case Map.get(workers, pid) do
            %Worker{ref: ^ref} -> Map.delete(workers, pid)
            _other -> workers
          end

        await_stopped(workers, deadline)
    after
      remaining ->
        Enum.each(workers, fn {_pid, worker} -> Process.demonitor(worker.ref, [:flush]) end)
        :ok
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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
