defmodule Jido.Cli.Automation.JSONL do
  @moduledoc "Writes atomic case records and explicit run-lifecycle artifacts."

  alias Jido.Cli.Automation.{Contract, Result}

  defstruct [:root, :tracker, :artifact_io, :output_writer, :utc_now, stdout: :stdio]

  @type t :: %__MODULE__{
          root: String.t() | nil,
          tracker: pid(),
          artifact_io: map(),
          output_writer: (IO.device(), iodata() -> :ok | {:error, term()}),
          utc_now: (-> DateTime.t() | String.t()),
          stdout: IO.device()
        }

  @doc "Opens an output sink and writes the manifest and running lifecycle."
  @spec open(map(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def open(manifest, output_dir, opts \\ []) do
    with {:ok, manifest} <- Contract.validate_manifest(manifest),
         {:ok, artifact_io} <- artifact_io(opts) do
      do_open(manifest, output_dir, sink_options(opts, artifact_io))
    end
  end

  defp do_open(manifest, nil, sink_opts), do: start_sink(manifest, nil, sink_opts)

  defp do_open(manifest, output_dir, sink_opts)
       when is_binary(output_dir) and output_dir != "" do
    root = Path.expand(output_dir)

    with :ok <- prepare_directory(root, sink_opts.artifact_io),
         :ok <- io_call(sink_opts.artifact_io, :mkdir_p, [Path.join(root, "by-agent")]) do
      start_sink(manifest, root, sink_opts)
    end
  end

  defp do_open(_manifest, output_dir, _sink_opts),
    do: {:error, {:invalid_output_directory, output_dir}}

  @doc "Records that execution started for one planned cell."
  @spec started(t(), map()) :: :ok | {:error, term()}
  def started(%__MODULE__{} = sink, cell) do
    cell_ref = cell_ref(cell)

    with :ok <- transition(sink, &start_cell(&1, cell_ref)),
         :ok <- write_lifecycle(sink) do
      :ok
    else
      {:error, reason} = error ->
        record_finalization_error(sink, :lifecycle, reason)
        error
    end
  end

  @doc "Writes one complete result as one physical JSON line."
  @spec emit(t(), map()) :: :ok | {:error, term()}
  def emit(%__MODULE__{} = sink, result) do
    with {:ok, result} <- Contract.validate_case_result(result),
         {:ok, json} <- Jason.encode(result),
         line = json <> "\n",
         :ok <- maybe_append(sink, "results.jsonl", line, :results),
         :ok <- maybe_append_agent(sink, result, line),
         :ok <- record_result(sink, result),
         :ok <- write_output(sink, line) do
      :ok
    else
      {:error, reason} = error ->
        if artifact_error?(reason), do: record_finalization_error(sink, artifact_phase(reason), reason)
        error
    end
  end

  @doc "Writes the summary atomically and records a terminal lifecycle state."
  @spec finish(t(), map()) :: :ok | {:error, term()}
  def finish(%__MODULE__{} = sink, summary) do
    with {:ok, summary} <- Contract.validate_summary(summary),
         :ok <- validate_finish(sink, summary) do
      finish_valid(sink, summary)
    else
      {:error, reason} = error ->
        _result = finalize_incomplete(sink, nil, :summary, reason)
        error
    end
  end

  @doc "Records an incomplete run after an execution or coordination failure."
  @spec abort(t(), term()) :: :ok | {:error, term()}
  def abort(%__MODULE__{} = sink, primary_error) do
    set_incomplete(sink, primary_error)
    write_incomplete(sink)
  end

  defp start_sink(manifest, root, sink_opts) do
    state = initial_state(manifest, root != nil, sink_opts.utc_now)

    with {:ok, tracker} <- Agent.start_link(fn -> state end) do
      sink = struct!(__MODULE__, Map.put(sink_opts, :root, root) |> Map.put(:tracker, tracker))

      case write_initial_files(sink, manifest) do
        :ok ->
          {:ok, sink}

        {:error, reason} = error ->
          record_finalization_error(sink, :initialization, reason)
          set_incomplete(sink, nil)
          _result = write_incomplete(sink)
          Agent.stop(tracker)
          error
      end
    end
  end

  defp write_initial_files(%__MODULE__{root: nil}, _manifest), do: :ok

  defp write_initial_files(sink, manifest) do
    with :ok <- write_json_atomic(sink, "manifest.json", manifest, :manifest),
         :ok <- write_lifecycle(sink) do
      :ok
    end
  end

  defp finish_valid(%__MODULE__{root: nil} = sink, summary) do
    set_terminal(sink, terminal_status(summary.status))
  end

  defp finish_valid(sink, summary) do
    case write_json_atomic(sink, "summary.json", summary, :summary) do
      :ok ->
        set_terminal(sink, terminal_status(summary.status))

        case write_lifecycle(sink) do
          :ok -> :ok
          {:error, reason} -> finalize_incomplete(sink, nil, :lifecycle, reason)
        end

      {:error, reason} ->
        finalize_incomplete(sink, nil, :summary, reason)
    end
  end

  defp finalize_incomplete(sink, primary_error, phase, reason) do
    record_finalization_error(sink, phase, reason)
    set_incomplete(sink, primary_error)

    case write_incomplete(sink) do
      :ok ->
        {:error, {:automation_artifact_finalization_failed, phase, reason}}

      {:error, lifecycle_reason} ->
        {:error, {:automation_artifact_finalization_failed, phase, reason, lifecycle_reason}}
    end
  end

  defp write_incomplete(%__MODULE__{root: nil}), do: :ok

  defp write_incomplete(sink) do
    case write_lifecycle(sink) do
      :ok ->
        :ok

      {:error, first_reason} ->
        record_finalization_error(sink, :lifecycle, first_reason)

        case write_lifecycle(sink) do
          :ok -> :ok
          {:error, second_reason} -> {:error, second_reason}
        end
    end
  end

  defp validate_finish(sink, summary) do
    Agent.get(sink.tracker, fn state ->
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

  defp record_result(sink, result) do
    result_ref = cell_ref(result)

    with :ok <- transition(sink, &complete_cell(&1, result_ref, result)),
         :ok <- write_lifecycle(sink) do
      :ok
    end
  end

  defp transition(sink, function) do
    Agent.get_and_update(sink.tracker, fn state ->
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

  defp set_terminal(sink, status) do
    Agent.update(sink.tracker, fn state ->
      %{state | status: status, finished_at: utc_iso(sink.utc_now)}
    end)

    :ok
  end

  defp set_incomplete(sink, primary_error) do
    Agent.update(sink.tracker, fn state ->
      primary = if is_nil(primary_error), do: state.primary_error, else: portable_error(primary_error, :execution)
      %{state | status: :incomplete, finished_at: utc_iso(sink.utc_now), primary_error: primary}
    end)
  end

  defp record_finalization_error(sink, phase, reason) do
    Agent.update(sink.tracker, fn state ->
      error = portable_error(reason, phase)
      %{state | finalization_errors: state.finalization_errors ++ [error]}
    end)
  end

  defp write_lifecycle(%__MODULE__{root: nil}), do: :ok

  defp write_lifecycle(sink) do
    lifecycle = Agent.get(sink.tracker, &lifecycle_projection/1)

    with {:ok, lifecycle} <- Contract.validate_lifecycle(lifecycle) do
      write_json_atomic(sink, "lifecycle.json", lifecycle, :lifecycle)
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

  defp terminal_status(:passed), do: :completed
  defp terminal_status(:failed), do: :failed
  defp terminal_status(:cancelled), do: :cancelled

  defp write_json_atomic(sink, relative_path, value, phase) do
    with {:ok, json} <- Jason.encode(value, pretty: true),
         :ok <- atomic_write(sink, relative_path, json <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, artifact_error(phase, reason)}
    end
  end

  defp maybe_append(%__MODULE__{root: nil}, _relative_path, _line, _phase), do: :ok

  defp maybe_append(sink, relative_path, line, phase) do
    path = Path.join(sink.root, relative_path)

    existing =
      case io_call(sink.artifact_io, :read, [path]) do
        {:ok, data} when is_binary(data) -> {:ok, data}
        {:error, :enoent} -> {:ok, ""}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_artifact_read_result, other}}
      end

    with {:ok, data} <- existing,
         :ok <- atomic_write(sink, relative_path, data <> line) do
      :ok
    else
      {:error, reason} -> {:error, artifact_error(phase, reason)}
    end
  end

  defp maybe_append_agent(%__MODULE__{root: nil}, _result, _line), do: :ok

  defp maybe_append_agent(sink, result, line) do
    agent_key = get_in(result, [:dimensions, :agent_key])
    relative = Path.join("by-agent", artifact_key(agent_key) <> ".jsonl")
    maybe_append(sink, relative, line, :by_agent)
  end

  defp atomic_write(sink, relative_path, data) do
    path = Path.join(sink.root, relative_path)
    temporary = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp")

    result =
      with :ok <- io_call(sink.artifact_io, :write, [temporary, data, []]),
           :ok <- io_call(sink.artifact_io, :chmod, [temporary, 0o600]),
           :ok <- io_call(sink.artifact_io, :rename, [temporary, path]),
           :ok <- io_call(sink.artifact_io, :chmod, [path, 0o600]) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        case remove_temporary(sink.artifact_io, temporary) do
          :ok ->
            {:error, reason}

          {:error, cleanup_reason} ->
            {:error, {:artifact_write_and_cleanup_failed, reason, cleanup_reason}}
        end
    end
  end

  defp write_output(sink, line) do
    if Agent.get(sink.tracker, & &1.stdout_open?) do
      result = safe_output_write(sink.output_writer, sink.stdout, line)

      if result != :ok do
        Agent.update(sink.tracker, &%{&1 | stdout_open?: false})
      end

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, artifact_error(:stdout, reason)}
      end
    else
      {:error, artifact_error(:stdout, :closed)}
    end
  end

  defp safe_output_write(writer, device, line) do
    case writer.(device, line) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_output_write_result, other}}
    end
  rescue
    exception -> {:error, {:output_write_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:output_write_throw, kind, reason}}
  end

  defp prepare_directory(root, artifact_io) do
    case io_call(artifact_io, :ls, [root]) do
      {:ok, []} -> :ok
      {:ok, entries} -> {:error, {:output_directory_not_empty, root, entries}}
      {:error, :enoent} -> io_call(artifact_io, :mkdir_p, [root])
      {:error, reason} -> {:error, {:output_directory_unavailable, root, reason}}
      other -> {:error, {:output_directory_unavailable, root, other}}
    end
  end

  defp artifact_io(opts) do
    defaults = %{
      ls: &File.ls/1,
      mkdir_p: &File.mkdir_p/1,
      read: &File.read/1,
      write: &File.write/3,
      rename: &File.rename/2,
      chmod: &File.chmod/2,
      rm: &File.rm/1
    }

    case Keyword.get(opts, :artifact_io, %{}) do
      overrides when is_map(overrides) or is_list(overrides) ->
        artifact_io = Map.merge(defaults, Map.new(overrides))

        if Enum.all?(defaults, fn {key, function} ->
             is_function(Map.get(artifact_io, key), :erlang.fun_info(function, :arity) |> elem(1))
           end) do
          {:ok, artifact_io}
        else
          {:error, :invalid_artifact_io}
        end

      _other ->
        {:error, :invalid_artifact_io}
    end
  rescue
    _exception -> {:error, :invalid_artifact_io}
  end

  defp sink_options(opts, artifact_io) do
    %{
      stdout: Keyword.get(opts, :output_device, :stdio),
      output_writer: Keyword.get(opts, :output_writer, &IO.write/2),
      utc_now: Keyword.get(opts, :utc_now, &DateTime.utc_now/0),
      artifact_io: artifact_io
    }
  end

  defp io_call(artifact_io, operation, arguments) do
    case apply(Map.fetch!(artifact_io, operation), arguments) do
      :ok -> :ok
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_artifact_io_result, operation, other}}
    end
  rescue
    exception -> {:error, {:artifact_io_exception, operation, exception.__struct__}}
  catch
    kind, reason -> {:error, {:artifact_io_throw, operation, kind, reason}}
  end

  defp remove_temporary(artifact_io, path) do
    case io_call(artifact_io, :rm, [path]) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
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
    normalized = Result.error(reason)

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

  defp artifact_error(phase, reason), do: {:automation_artifact_write_failed, phase, reason}
  defp artifact_error?({:automation_artifact_write_failed, _phase, _reason}), do: true
  defp artifact_error?(_reason), do: false
  defp artifact_phase({:automation_artifact_write_failed, phase, _reason}), do: phase

  defp artifact_key(key) when is_binary(key) do
    safe =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.replace(~r/^[.-]+|[.-]+$/, "")

    if safe != "" and safe == key do
      safe
    else
      digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> String.slice(0, 12)
      "#{if(safe == "", do: "agent", else: safe)}-#{digest}"
    end
  end
end
