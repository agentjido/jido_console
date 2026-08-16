defmodule Jido.Console.Automation.Coordinator do
  @moduledoc """
  Runs automation cells with bounded, unordered completion and cancellation.

  Engines expose only their public request handles to this coordinator. A
  cancellation stops new admission before it asks each active engine request
  to stop.
  """

  alias Jido.Console.Automation.{Contract, Interrupt, JSONL, Limits, Result}

  @type stop_cause :: nil | :cancelled | {:limit, map()}
  @type outcome :: %{
          results: [map()],
          stop_cause: stop_cause(),
          not_started: [map()]
        }

  @doc false
  @spec run([map()], JSONL.t(), module(), pos_integer(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def run(cells, sink, engine, jobs, opts)
      when is_list(cells) and is_integer(jobs) and jobs > 0 and is_list(opts) do
    limits = Keyword.fetch!(opts, :automation_limits)

    state = %{
      pending: cells,
      active: %{},
      results: [],
      stop_cause: nil,
      limits: limits,
      started_ms: monotonic_ms(opts)
    }

    with {:ok, state} <- admit(state, sink, engine, jobs, opts) do
      loop(state, sink, engine, jobs, opts)
    end
  end

  defp loop(%{active: active, pending: pending} = state, _sink, _engine, _jobs, opts)
       when map_size(active) == 0 and
              (pending == [] or not is_nil(state.stop_cause)) do
    write_stop_diagnostic(state.stop_cause, opts)

    {:ok,
     %{
       results: Enum.reverse(state.results),
       stop_cause: state.stop_cause,
       not_started: state.pending
     }}
  end

  defp loop(state, sink, engine, jobs, opts) do
    cancel_tag = Interrupt.message_tag()

    receive do
      {^cancel_tag, reason} ->
        state
        |> accept_cancellation(reason, engine, opts)
        |> loop(sink, engine, jobs, opts)

      {ref, result} when is_reference(ref) ->
        complete_task(state, ref, result, sink, engine, jobs, opts)

      {:DOWN, ref, :process, _pid, reason} when is_reference(ref) ->
        fail_task(state, ref, reason, sink, engine, jobs, opts)
    after
      Limits.receive_timeout(state.limits, elapsed_ms(state, opts)) ->
        state
        |> apply_limit_stop(engine, opts)
        |> loop(sink, engine, jobs, opts)
    end
  end

  defp admit(state, sink, engine, jobs, opts) do
    state = apply_limit_stop(state, engine, opts)

    cond do
      not is_nil(state.stop_cause) ->
        {:ok, state}

      map_size(state.active) >= jobs or state.pending == [] ->
        {:ok, state}

      true ->
        admit_next(state, sink, engine, jobs, opts)
    end
  end

  defp admit_next(state, sink, engine, jobs, opts) do
    case pop_admissible(state) do
      :none ->
        {:ok, state}

      {:ok, cell, pending} ->
        state = %{state | pending: pending}

        case JSONL.started(sink, cell) do
          :ok ->
            case start_cell(engine, cell, opts) do
              {:ok, entry} ->
                state
                |> put_active(Map.put(entry, :provider, Limits.provider_key(cell)))
                |> admit(sink, engine, jobs, opts)

              {:error, reason} ->
                emit_start_error(state, cell, reason, sink, engine, jobs, opts)
            end

          {:error, reason} ->
            abort_active(state, engine, opts)
            {:error, reason}
        end
    end
  end

  defp emit_start_error(state, cell, reason, sink, engine, jobs, opts) do
    result = engine_error(cell, reason, opts)

    case JSONL.emit(sink, result) do
      :ok ->
        state
        |> Map.update!(:results, &[result | &1])
        |> admit(sink, engine, jobs, opts)

      {:error, reason} ->
        abort_active(state, engine, opts)
        {:error, reason}
    end
  end

  defp start_cell(engine, cell, opts) do
    case safe_apply(engine, :start, [cell, opts]) do
      {:ok, request} ->
        task = Task.async(fn -> safe_engine_await(engine, request, cell, opts) end)
        {:ok, %{task: task, cell: cell, request: request}}

      {:error, reason} ->
        {:error, reason}

      result ->
        {:error, {:invalid_engine_start_result, result}}
    end
  end

  defp complete_task(state, ref, result, sink, engine, jobs, opts) do
    case Map.pop(state.active, ref) do
      {nil, _active} ->
        loop(state, sink, engine, jobs, opts)

      {%{task: task}, active} ->
        Process.demonitor(task.ref, [:flush])
        state = %{state | active: active}

        case JSONL.emit(sink, result) do
          :ok ->
            state
            |> Map.update!(:results, &[result | &1])
            |> admit(sink, engine, jobs, opts)
            |> continue_loop(sink, engine, jobs, opts)

          {:error, reason} ->
            abort_active(state, engine, opts)
            {:error, reason}
        end
    end
  end

  defp fail_task(state, ref, reason, sink, engine, jobs, opts) do
    case Map.pop(state.active, ref) do
      {nil, _active} ->
        loop(state, sink, engine, jobs, opts)

      {%{cell: cell}, active} ->
        result = engine_error(cell, {:automation_task_exit, reason}, opts)
        state = %{state | active: active}

        case JSONL.emit(sink, result) do
          :ok ->
            state
            |> Map.update!(:results, &[result | &1])
            |> admit(sink, engine, jobs, opts)
            |> continue_loop(sink, engine, jobs, opts)

          {:error, reason} ->
            abort_active(state, engine, opts)
            {:error, reason}
        end
    end
  end

  defp accept_cancellation(%{stop_cause: :cancelled} = state, _reason, _engine, _opts),
    do: state

  defp accept_cancellation(state, reason, engine, opts) do
    state = %{state | stop_cause: :cancelled}
    write_diagnostic(reason, opts)

    Enum.each(state.active, fn {_ref, entry} ->
      cancel_entry(engine, entry, opts)
    end)

    state
  end

  defp apply_limit_stop(%{stop_cause: cause} = state, _engine, _opts) when not is_nil(cause),
    do: state

  defp apply_limit_stop(state, engine, opts) do
    case Limits.stop_reason(state.limits, state.results, elapsed_ms(state, opts)) do
      nil ->
        state

      reason ->
        state = %{state | stop_cause: {:limit, reason}}

        if state.limits.cancel_active_on_stop do
          abort_active(state, engine, opts)
        end

        state
    end
  end

  defp continue_loop({:ok, state}, sink, engine, jobs, opts),
    do: loop(state, sink, engine, jobs, opts)

  defp continue_loop({:error, _reason} = error, _sink, _engine, _jobs, _opts), do: error

  defp abort_active(state, engine, opts) do
    Enum.each(state.active, fn {_ref, entry} -> cancel_entry(engine, entry, opts) end)
  end

  defp cancel_entry(engine, %{cell: cell, request: request}, opts) do
    grace_ms = positive_integer(Keyword.get(opts, :cancellation_grace_ms), 100)

    case safe_apply(engine, :cancel, [request, [grace_ms: grace_ms]]) do
      {:ok, _evidence} -> :ok
      {:error, :request_already_finished} -> :ok
      {:error, reason} -> write_cancel_error(cell, reason, opts)
      result -> write_cancel_error(cell, {:invalid_engine_cancel_result, result}, opts)
    end
  end

  defp safe_engine_await(engine, request, cell, opts) do
    engine
    |> safe_apply(:await, [request, opts])
    |> normalize_engine_result(cell, opts)
  end

  defp normalize_engine_result(%{} = result, cell, opts) do
    case Contract.validate_case_result(result) do
      {:ok, result} -> result
      {:error, reason} -> engine_error(cell, reason, opts)
    end
  end

  defp normalize_engine_result({:error, reason}, cell, opts),
    do: engine_error(cell, reason, opts)

  defp normalize_engine_result(result, cell, opts),
    do: engine_error(cell, {:invalid_engine_result, result}, opts)

  defp engine_error(cell, reason, opts) do
    Result.new(cell,
      execution: %{
        status: :error,
        started_at: utc_now(opts) |> DateTime.to_iso8601(),
        duration_ms: 0,
        turn_count: 0
      },
      evaluation: Result.evaluation([], :error),
      turns: [],
      usage: %{},
      error: Result.error(reason)
    )
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp put_active(state, %{task: %Task{ref: ref}} = entry) do
    %{state | active: Map.put(state.active, ref, entry)}
  end

  defp pop_admissible(state) do
    index =
      Enum.find_index(state.pending, fn cell ->
        provider = Limits.provider_key(cell)
        provider_active(state.active, provider) < Limits.provider_limit(state.limits, cell)
      end)

    case index do
      nil ->
        :none

      index ->
        {cell, pending} = List.pop_at(state.pending, index)
        {:ok, cell, pending}
    end
  end

  defp provider_active(active, provider) do
    Enum.count(active, fn {_ref, entry} -> Map.get(entry, :provider) == provider end)
  end

  defp write_diagnostic(reason, opts) do
    device = Keyword.get(opts, :error_device, :stderr)
    IO.puts(device, "jido: automated run cancelled: #{inspect(reason)}")
  end

  defp write_cancel_error(cell, reason, opts) do
    device = Keyword.get(opts, :error_device, :stderr)
    IO.puts(device, "jido: could not cancel cell #{cell.cell_id}: #{inspect(reason)}")
  end

  defp write_limit_diagnostic(reason, opts) do
    device = Keyword.get(opts, :error_device, :stderr)
    IO.puts(device, "jido: automated run limit reached: #{inspect(reason)}")
  end

  defp write_stop_diagnostic({:limit, reason}, opts), do: write_limit_diagnostic(reason, opts)
  defp write_stop_diagnostic(_cause, _opts), do: :ok

  defp utc_now(opts) do
    case Keyword.get(opts, :utc_now) do
      function when is_function(function, 0) -> function.()
      _function -> DateTime.utc_now()
    end
  end

  defp monotonic_ms(opts) do
    case Keyword.get(opts, :monotonic_ms) do
      function when is_function(function, 0) -> function.()
      _function -> System.monotonic_time(:millisecond)
    end
  end

  defp elapsed_ms(state, opts), do: max(monotonic_ms(opts) - state.started_ms, 0)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
