defmodule Jido.Cli.Tui.Shutdown do
  @moduledoc false

  alias Jido.Cli.Tui.{Effects, Workers}
  alias Jido.Cli.Tui.Workers.Worker

  @timeout_ms 250
  @cancel_timeout_ms 100
  @start_grace_ms 25
  @reap_timeout_ms 100

  @spec run(Jido.Cli.Tui.State.t(), Workers.t(), module(), keyword()) :: :ok
  def run(state, workers, runtime, opts) do
    deadline = deadline(option_timeout(opts, :shutdown_timeout_ms, @timeout_ms))
    {request, workers} = settle_start_turn(state.request, workers, opts, deadline)
    request = request || active_worker_request(workers)

    if request && not cancelling?(workers, request) do
      _outcome = cancel_bounded(runtime, request, opts, deadline)
    end

    workers = await_terminal(workers, request, deadline)
    Workers.stop_all(workers, option_timeout(opts, :shutdown_reap_timeout_ms, @reap_timeout_ms))
  end

  defp settle_start_turn(request, workers, _opts, _deadline) when not is_nil(request),
    do: {request, workers}

  defp settle_start_turn(nil, workers, opts, deadline) do
    case Enum.find(workers, fn {_pid, worker} -> match?(%Worker{kind: {:start_turn, _relay}}, worker) end) do
      {pid, %Worker{ref: ref}} ->
        grace = min(option_timeout(opts, :shutdown_start_grace_ms, @start_grace_ms), remaining_ms(deadline))

        receive do
          {:jido_tui_effect_result, ^pid, outcome} ->
            case Workers.pop(workers, pid) do
              {:ok, worker, workers} ->
                Workers.reap(pid, option_timeout(opts, :shutdown_reap_timeout_ms, @reap_timeout_ms))
                start_request(Effects.complete(worker, outcome), workers)

              :error ->
                {nil, workers}
            end

          {:DOWN, ^ref, :process, ^pid, _reason} ->
            case Workers.take_down(workers, pid, ref) do
              {:ok, _worker, workers} -> {nil, workers}
              :error -> {nil, workers}
            end
        after
          grace -> {nil, workers}
        end

      nil ->
        {nil, workers}
    end
  end

  defp start_request({:start_turn, _relay_pid, {:turn_started, request}}, workers),
    do: {request, workers}

  defp start_request(_completion, workers), do: {nil, workers}

  defp active_worker_request(workers) do
    Enum.find_value(workers, fn
      {_pid, %Worker{kind: kind, subject: request}} when kind in [:await_turn, :cancel_turn] ->
        request

      {_pid, %Worker{kind: {:respond_review, _decision, _relay}, subject: %{handle: request}}} ->
        request

      _worker ->
        nil
    end)
  end

  defp cancelling?(workers, request) do
    Enum.any?(workers, fn
      {_pid, %Worker{kind: :cancel_turn, subject: ^request}} -> true
      _worker -> false
    end)
  end

  defp cancel_bounded(runtime, request, opts, deadline) do
    owner = self()
    cancel_opts = Keyword.get(opts, :cancel_opts, [])

    {pid, ref} =
      :erlang.spawn_opt(
        fn -> send(owner, {:jido_shutdown_cancelled, self(), safe_cancel(runtime, request, cancel_opts)}) end,
        [:link, :monitor]
      )

    timeout =
      opts
      |> option_timeout(:shutdown_cancel_timeout_ms, @cancel_timeout_ms)
      |> min(remaining_ms(deadline))

    receive do
      {:jido_shutdown_cancelled, ^pid, outcome} ->
        _stopped? = await_process_down(pid, ref, option_timeout(opts, :shutdown_reap_timeout_ms, @reap_timeout_ms))
        Process.demonitor(ref, [:flush])
        outcome

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:shutdown_cancel_failed, reason}}
    after
      timeout ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        reap_timeout = option_timeout(opts, :shutdown_reap_timeout_ms, @reap_timeout_ms)
        _stopped? = await_process_down(pid, ref, reap_timeout)
        {:error, :shutdown_cancel_timeout}
    end
  end

  defp safe_cancel(runtime, request, opts) do
    runtime.cancel(request, opts)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_terminal(workers, nil, _deadline), do: workers

  defp await_terminal(workers, request, deadline) do
    terminal_workers = Map.filter(workers, fn {_pid, worker} -> terminal_worker?(worker, request) end)
    await_terminal_workers(workers, terminal_workers, request, deadline)
  end

  defp terminal_worker?(%Worker{kind: kind, subject: request}, request)
       when kind in [:await_turn, :cancel_turn],
       do: true

  defp terminal_worker?(%Worker{kind: {:respond_review, _decision, _relay}, subject: %{handle: request}}, request),
    do: true

  defp terminal_worker?(_worker, _request), do: false

  defp await_terminal_workers(workers, terminal_workers, _request, _deadline)
       when map_size(terminal_workers) == 0,
       do: workers

  defp await_terminal_workers(workers, terminal_workers, request, deadline) do
    receive do
      {:jido_tui_effect_result, pid, _outcome} when is_map_key(terminal_workers, pid) ->
        case Workers.pop(workers, pid) do
          {:ok, _worker, workers} ->
            Workers.reap(pid, @reap_timeout_ms)
            workers

          :error ->
            workers
        end

      {:DOWN, ref, :process, pid, _reason} when is_map_key(terminal_workers, pid) ->
        terminal_workers = Map.delete(terminal_workers, pid)

        workers =
          case Workers.take_down(workers, pid, ref) do
            {:ok, _worker, workers} -> workers
            :error -> workers
          end

        await_terminal_workers(workers, terminal_workers, request, deadline)

      {:jido_turn_result, ^request, _result} ->
        workers
    after
      remaining_ms(deadline) -> workers
    end
  end

  defp await_process_down(pid, ref, timeout_ms) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      timeout_ms -> not Process.alive?(pid)
    end
  end

  defp option_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
