defmodule Jido.Console.Automation.JSONL.Tracker do
  @moduledoc "Owns automation run lifecycle transitions and projections."

  alias Jido.Console.Automation.ResultValue

  @opaque reservation :: %{
            cell_ref: map(),
            result_status: :completed | :failed | :cancelled,
            token: reference()
          }

  @doc "Starts one lifecycle tracker."
  @spec start(map(), (-> DateTime.t() | String.t())) :: Agent.on_start()
  def start(manifest, utc_now) do
    Agent.start_link(fn -> initial_state(manifest, utc_now) end)
  end

  @doc "Records that one planned cell started."
  @spec started(pid(), map()) :: :ok | {:error, term()}
  def started(tracker, cell), do: transition(tracker, &start_cell(&1, cell_ref(cell)))

  @doc "Reserves one planned cell result before output writes start."
  @spec reserve_result(pid(), map()) :: {:ok, reservation()} | {:error, term()}
  def reserve_result(tracker, result) do
    Agent.get_and_update(tracker, fn state ->
      case reserve_cell(state, cell_ref(result), result) do
        {:ok, reservation, next} -> {{:ok, reservation}, next}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  @doc "Commits one reserved result after all result outputs succeed."
  @spec commit_result(pid(), reservation()) :: :ok | {:error, term()}
  def commit_result(tracker, reservation), do: transition(tracker, &commit_cell(&1, reservation))

  @doc "Releases one reserved result after a result output fails."
  @spec release_result(pid(), reservation()) :: :ok | {:error, term()}
  def release_result(tracker, reservation), do: transition(tracker, &release_cell(&1, reservation))

  @doc "Checks that a summary agrees with the tracked run."
  @spec validate_finish(pid(), map()) :: :ok | {:error, term()}
  def validate_finish(tracker, summary) do
    Agent.get(tracker, fn state ->
      cond do
        state.status != :running ->
          {:error, {:invalid_lifecycle_transition, state.status, :finish}}

        summary.run_id != state.run_id ->
          {:error, {:invalid_lifecycle_run_id, summary.run_id}}

        summary.planned != map_size(state.planned) ->
          {:error, {:invalid_lifecycle_planned_count, summary.planned, map_size(state.planned)}}

        summary.completed != map_size(state.completed) ->
          {:error, {:invalid_lifecycle_completed_count, summary.completed, map_size(state.completed)}}

        true ->
          :ok
      end
    end)
  end

  @doc "Sets a terminal run status."
  @spec terminal(pid(), atom(), (-> DateTime.t() | String.t())) :: :ok
  def terminal(tracker, status, utc_now) do
    Agent.update(tracker, &%{&1 | status: status, finished_at: utc_iso(utc_now)})
  end

  @doc "Marks the run incomplete and keeps the first execution error."
  @spec incomplete(pid(), term(), (-> DateTime.t() | String.t())) :: :ok
  def incomplete(tracker, primary_error, utc_now) do
    Agent.update(tracker, fn state ->
      primary = if is_nil(primary_error), do: state.primary_error, else: portable_error(primary_error, :execution)
      %{state | status: :incomplete, finished_at: utc_iso(utc_now), primary_error: primary}
    end)
  end

  @doc "Adds one artifact finalization error."
  @spec finalization_error(pid(), atom(), term()) :: :ok
  def finalization_error(tracker, phase, reason) do
    Agent.update(tracker, fn state ->
      error = portable_error(reason, phase)
      %{state | finalization_errors: state.finalization_errors ++ [error]}
    end)
  end

  @doc "Returns the validated lifecycle source value."
  @spec projection(pid()) :: map()
  def projection(tracker), do: Agent.get(tracker, &lifecycle_projection/1)

  @doc "Returns true while the standard output stream accepts records."
  @spec stdout_open?(pid()) :: boolean()
  def stdout_open?(tracker), do: Agent.get(tracker, & &1.stdout_open?)

  @doc "Marks standard output closed after its first write error."
  @spec close_stdout(pid()) :: :ok
  def close_stdout(tracker), do: Agent.update(tracker, &%{&1 | stdout_open?: false})

  defp transition(tracker, function) do
    Agent.get_and_update(tracker, fn state ->
      case function.(state) do
        {:ok, next} -> {:ok, next}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  defp start_cell(%{status: :running} = state, cell_ref) do
    with {:ok, state} <- ensure_planned(state, cell_ref),
         false <- Map.has_key?(state.started, cell_ref.cell_id) do
      {:ok, put_in(state, [:started, cell_ref.cell_id], cell_ref)}
    else
      true -> {:error, {:invalid_lifecycle_transition, cell_ref.cell_id, :already_started}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_cell(state, _cell_ref),
    do: {:error, {:invalid_lifecycle_transition, state.status, :start}}

  defp reserve_cell(%{status: :running} = state, cell_ref, result) do
    with {:ok, state} <- ensure_planned(state, cell_ref),
         :ok <- ensure_not_completed(state, cell_ref),
         :ok <- ensure_not_reserved(state, cell_ref),
         {:ok, state} <- ensure_started(state, cell_ref) do
      reservation = %{
        cell_ref: cell_ref,
        result_status: cell_status(result),
        token: make_ref()
      }

      {:ok, reservation, put_in(state, [:reserved, cell_ref.cell_id], reservation)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_cell(state, _cell_ref, _result),
    do: {:error, {:invalid_lifecycle_transition, state.status, :reserve_result}}

  defp commit_cell(%{status: :running} = state, reservation) do
    cell_ref = reservation.cell_ref

    case Map.fetch(state.reserved, cell_ref.cell_id) do
      {:ok, ^reservation} ->
        state =
          state
          |> update_in([:reserved], &Map.delete(&1, cell_ref.cell_id))
          |> put_in([:completed, cell_ref.cell_id], cell_ref)
          |> put_result_status(reservation.result_status, cell_ref)

        {:ok, state}

      {:ok, _other} ->
        {:error, {:invalid_lifecycle_result_reservation, cell_ref.cell_id}}

      :error ->
        {:error, {:missing_lifecycle_result_reservation, cell_ref.cell_id}}
    end
  end

  defp commit_cell(state, _reservation),
    do: {:error, {:invalid_lifecycle_transition, state.status, :commit_result}}

  defp release_cell(%{status: :running} = state, reservation) do
    cell_ref = reservation.cell_ref

    case Map.fetch(state.reserved, cell_ref.cell_id) do
      {:ok, ^reservation} ->
        {:ok, update_in(state, [:reserved], &Map.delete(&1, cell_ref.cell_id))}

      {:ok, _other} ->
        {:error, {:invalid_lifecycle_result_reservation, cell_ref.cell_id}}

      :error ->
        {:error, {:missing_lifecycle_result_reservation, cell_ref.cell_id}}
    end
  end

  defp release_cell(state, _reservation),
    do: {:error, {:invalid_lifecycle_transition, state.status, :release_result}}

  defp ensure_not_completed(state, cell_ref) do
    if Map.has_key?(state.completed, cell_ref.cell_id),
      do: {:error, {:invalid_lifecycle_transition, cell_ref.cell_id, :already_completed}},
      else: :ok
  end

  defp ensure_not_reserved(state, cell_ref) do
    if Map.has_key?(state.reserved, cell_ref.cell_id),
      do: {:error, {:invalid_lifecycle_transition, cell_ref.cell_id, :already_reserved}},
      else: :ok
  end

  defp put_result_status(state, :failed, cell_ref),
    do: put_in(state, [:failed, cell_ref.cell_id], cell_ref)

  defp put_result_status(state, :cancelled, cell_ref),
    do: put_in(state, [:cancelled, cell_ref.cell_id], cell_ref)

  defp put_result_status(state, :completed, _cell_ref), do: state

  defp ensure_started(state, cell_ref) do
    case Map.fetch(state.started, cell_ref.cell_id) do
      {:ok, ^cell_ref} -> {:ok, state}
      {:ok, other} -> {:error, {:lifecycle_cell_mismatch, cell_ref, other}}
      :error -> {:ok, put_in(state, [:started, cell_ref.cell_id], cell_ref)}
    end
  end

  defp ensure_planned(state, cell_ref) do
    case Map.fetch(state.planned, cell_ref.cell_id) do
      {:ok, ^cell_ref} -> {:ok, state}
      {:ok, other} -> {:error, {:lifecycle_cell_mismatch, cell_ref, other}}
      :error -> {:error, {:unplanned_lifecycle_cell, cell_ref}}
    end
  end

  defp lifecycle_projection(state) do
    planned = refs(state.planned)
    completed = refs(state.completed)
    completed_ids = Map.keys(state.completed) |> MapSet.new()

    %{
      schema: "jido.run-lifecycle",
      schema_version: 1,
      run_id: state.run_id,
      suite_id: state.suite_id,
      status: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      planned: planned,
      started: refs(state.started),
      completed: completed,
      failed: refs(state.failed),
      cancelled: refs(state.cancelled),
      missing: Enum.reject(planned, &MapSet.member?(completed_ids, &1.cell_id)),
      primary_error: state.primary_error,
      finalization_errors: state.finalization_errors
    }
  end

  defp refs(values) do
    values
    |> Map.values()
    |> Enum.sort_by(&{&1.sequence, &1.cell_id})
  end

  defp cell_status(result) do
    execution = get_in(result, [:execution, :status])
    evaluation = get_in(result, [:evaluation, :status])

    cond do
      execution == :cancelled -> :cancelled
      execution != :ok or evaluation == :failed -> :failed
      true -> :completed
    end
  end

  defp initial_state(manifest, utc_now) do
    planned = Map.new(manifest.cells, fn cell -> {cell.cell_id, cell_ref(cell)} end)

    %{
      run_id: manifest.run_id,
      suite_id: manifest.suite_id,
      status: :running,
      started_at: utc_iso(utc_now),
      finished_at: nil,
      planned: planned,
      started: %{},
      reserved: %{},
      completed: %{},
      failed: %{},
      cancelled: %{},
      primary_error: nil,
      finalization_errors: [],
      stdout_open?: true
    }
  end

  defp cell_ref(value), do: %{cell_id: value.cell_id, sequence: value.sequence}

  defp portable_error(reason, phase) do
    normalized = ResultValue.error(reason)

    %{
      category: Map.get(normalized, :category, "execution"),
      message: "Automation #{phase} failed.",
      phase: Atom.to_string(phase),
      details: %{codes: reason_codes(reason) |> Enum.take(8)}
    }
  end

  defp reason_codes(value) when is_atom(value), do: [Atom.to_string(value)]
  defp reason_codes(%{__struct__: module}), do: [inspect(module)]

  defp reason_codes(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&reason_codes/1) |> Enum.uniq()

  defp reason_codes(value) when is_list(value),
    do: value |> Enum.flat_map(&reason_codes/1) |> Enum.uniq()

  defp reason_codes(_value), do: []

  defp utc_iso(function) do
    case function.() do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value when is_binary(value) and value != "" -> value
      _value -> "unknown"
    end
  rescue
    _exception -> "unknown"
  end
end
