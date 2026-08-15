defmodule Jido.Console.Automation.JSONL.Tracker do
  @moduledoc "Owns automation run lifecycle transitions and projections."

  alias Jido.Console.Automation.ResultValue

  @doc "Starts one lifecycle tracker."
  @spec start(map(), boolean(), (-> DateTime.t() | String.t())) :: Agent.on_start()
  def start(manifest, strict?, utc_now) do
    Agent.start_link(fn -> initial_state(manifest, strict?, utc_now) end)
  end

  @doc "Records that one planned cell started."
  @spec started(pid(), map()) :: :ok | {:error, term()}
  def started(tracker, cell), do: transition(tracker, &start_cell(&1, cell_ref(cell)))

  @doc "Records one complete cell result."
  @spec complete(pid(), map()) :: :ok | {:error, term()}
  def complete(tracker, result), do: transition(tracker, &complete_cell(&1, cell_ref(result), result))

  @doc "Checks that a summary agrees with the tracked run."
  @spec validate_finish(pid(), map()) :: :ok | {:error, term()}
  def validate_finish(tracker, summary) do
    Agent.get(tracker, fn state ->
      cond do
        state.status != :running ->
          {:error, {:invalid_lifecycle_transition, state.status, :finish}}

        summary.run_id != state.run_id ->
          {:error, {:invalid_lifecycle_run_id, summary.run_id}}

        state.strict? and summary.planned != map_size(state.planned) ->
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

  defp complete_cell(%{status: :running} = state, cell_ref, result) do
    with {:ok, state} <- ensure_planned(state, cell_ref),
         false <- Map.has_key?(state.completed, cell_ref.cell_id),
         {:ok, state} <- ensure_started(state, cell_ref) do
      state = put_in(state, [:completed, cell_ref.cell_id], cell_ref)

      state =
        case cell_status(result) do
          :failed -> put_in(state, [:failed, cell_ref.cell_id], cell_ref)
          :cancelled -> put_in(state, [:cancelled, cell_ref.cell_id], cell_ref)
          :completed -> state
        end

      {:ok, state}
    else
      true -> {:error, {:invalid_lifecycle_transition, cell_ref.cell_id, :already_completed}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_cell(state, _cell_ref, _result),
    do: {:error, {:invalid_lifecycle_transition, state.status, :complete}}

  defp ensure_started(state, cell_ref) do
    case Map.fetch(state.started, cell_ref.cell_id) do
      {:ok, ^cell_ref} -> {:ok, state}
      {:ok, other} -> {:error, {:lifecycle_cell_mismatch, cell_ref, other}}
      :error -> {:ok, put_in(state, [:started, cell_ref.cell_id], cell_ref)}
    end
  end

  defp ensure_planned(%{strict?: false} = state, cell_ref) do
    {:ok, put_in(state, [:planned, cell_ref.cell_id], cell_ref)}
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

  defp initial_state(manifest, strict?, utc_now) do
    planned = Map.new(manifest.cells, fn cell -> {cell.cell_id, cell_ref(cell)} end)

    %{
      run_id: manifest.run_id,
      suite_id: manifest.suite_id,
      strict?: strict?,
      status: :running,
      started_at: utc_iso(utc_now),
      finished_at: nil,
      planned: planned,
      started: %{},
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
