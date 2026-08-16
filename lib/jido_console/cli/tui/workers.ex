defmodule Jido.Console.Tui.Workers do
  @moduledoc """
  Renderer-local effect tasks. They do not own a Jidoka session, queue, or
  Console event order. Session ownership is `Jido.Console.Session.Client`.
  """

  @shutdown_timeout_ms 250

  defmodule Worker do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{pid: Zoi.pid(), ref: Zoi.reference(), kind: Zoi.any()},
              unrecognized_keys: :error
            )

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @type t :: %__MODULE__{
            pid: pid(),
            ref: reference(),
            kind: term()
          }
  end

  @type t :: %{optional(pid()) => Worker.t()}

  @spec start(t(), term(), (-> term())) :: t()
  def start(workers, kind, fun) when is_map(workers) and is_function(fun, 0) do
    owner = self()

    {pid, ref} =
      spawn_link_monitor(fn ->
        send(owner, {:jido_tui_effect_result, self(), safe_effect(fun)})
      end)

    put(workers, pid, ref, kind)
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
  def take_completion(workers, pid), do: pop(workers, pid)

  @spec take_down(t(), pid(), reference()) :: {:ok, Worker.t(), t()} | :error
  def take_down(workers, pid, ref) do
    case Map.get(workers, pid) do
      %Worker{ref: ^ref} = worker -> {:ok, worker, Map.delete(workers, pid)}
      _other -> :error
    end
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

  defp put(workers, pid, ref, kind),
    do: Map.put(workers, pid, %Worker{pid: pid, ref: ref, kind: kind})

  defp spawn_link_monitor(fun), do: :erlang.spawn_opt(fun, [:link, :monitor])

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
end
