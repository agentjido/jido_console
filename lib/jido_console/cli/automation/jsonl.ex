defmodule Jido.Console.Automation.JSONL do
  @moduledoc "Writes atomic case records and explicit run-lifecycle artifacts."

  alias Jido.Console.Automation.Contract
  alias Jido.Console.Automation.JSONL.{Artifact, Tracker}

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
         {:ok, artifact_io} <- Artifact.configure(opts) do
      do_open(manifest, output_dir, sink_options(opts, artifact_io))
    end
  end

  defp do_open(manifest, nil, sink_opts), do: start_sink(manifest, nil, sink_opts)

  defp do_open(manifest, output_dir, sink_opts) when is_binary(output_dir) and output_dir != "" do
    root = Path.expand(output_dir)

    with :ok <- Artifact.prepare_directory(root, sink_opts.artifact_io),
         :ok <- Artifact.prepare_agent_directory(root, sink_opts.artifact_io) do
      start_sink(manifest, root, sink_opts)
    end
  end

  defp do_open(_manifest, output_dir, _sink_opts),
    do: {:error, {:invalid_output_directory, output_dir}}

  @doc "Records that execution started for one planned cell."
  @spec started(t(), map()) :: :ok | {:error, term()}
  def started(%__MODULE__{} = sink, cell) do
    with :ok <- Tracker.started(sink.tracker, cell),
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
        if Artifact.error?(reason), do: record_finalization_error(sink, Artifact.phase(reason), reason)
        error
    end
  end

  @doc "Writes the summary atomically and records a terminal lifecycle state."
  @spec finish(t(), map()) :: :ok | {:error, term()}
  def finish(%__MODULE__{} = sink, summary) do
    with {:ok, summary} <- Contract.validate_summary(summary),
         :ok <- Tracker.validate_finish(sink.tracker, summary) do
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
    Tracker.incomplete(sink.tracker, primary_error, sink.utc_now)
    write_incomplete(sink)
  end

  defp start_sink(manifest, root, sink_opts) do
    with {:ok, tracker} <- Tracker.start(manifest, sink_opts.utc_now) do
      sink = struct!(__MODULE__, Map.put(sink_opts, :root, root) |> Map.put(:tracker, tracker))

      case write_initial_files(sink, manifest) do
        :ok ->
          {:ok, sink}

        {:error, reason} = error ->
          record_finalization_error(sink, :initialization, reason)
          Tracker.incomplete(sink.tracker, nil, sink.utc_now)
          _result = write_incomplete(sink)
          Agent.stop(tracker)
          error
      end
    end
  end

  defp write_initial_files(%__MODULE__{root: nil}, _manifest), do: :ok

  defp write_initial_files(sink, manifest) do
    with :ok <- write_json(sink, "manifest.json", manifest, :manifest) do
      write_lifecycle(sink)
    end
  end

  defp finish_valid(%__MODULE__{root: nil} = sink, summary) do
    Tracker.terminal(sink.tracker, terminal_status(summary.status), sink.utc_now)
  end

  defp finish_valid(sink, summary) do
    case write_json(sink, "summary.json", summary, :summary) do
      :ok ->
        Tracker.terminal(sink.tracker, terminal_status(summary.status), sink.utc_now)

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
    Tracker.incomplete(sink.tracker, primary_error, sink.utc_now)

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

  defp record_result(sink, result) do
    with :ok <- Tracker.complete(sink.tracker, result) do
      write_lifecycle(sink)
    end
  end

  defp record_finalization_error(sink, phase, reason),
    do: Tracker.finalization_error(sink.tracker, phase, reason)

  defp write_lifecycle(%__MODULE__{root: nil}), do: :ok

  defp write_lifecycle(sink) do
    lifecycle = Tracker.projection(sink.tracker)

    with {:ok, lifecycle} <- Contract.validate_lifecycle(lifecycle) do
      write_json(sink, "lifecycle.json", lifecycle, :lifecycle)
    end
  end

  defp terminal_status(:passed), do: :completed
  defp terminal_status(:failed), do: :failed
  defp terminal_status(:cancelled), do: :cancelled

  defp write_json(sink, relative_path, value, phase),
    do: Artifact.write_json(sink.artifact_io, sink.root, relative_path, value, phase)

  defp maybe_append(%__MODULE__{root: nil}, _relative_path, _line, _phase), do: :ok

  defp maybe_append(sink, relative_path, line, phase),
    do: Artifact.append(sink.artifact_io, sink.root, relative_path, line, phase)

  defp maybe_append_agent(%__MODULE__{root: nil}, _result, _line), do: :ok

  defp maybe_append_agent(sink, result, line) do
    result
    |> get_in([:dimensions, :agent_key])
    |> Artifact.agent_path()
    |> then(&maybe_append(sink, &1, line, :by_agent))
  end

  defp write_output(sink, line) do
    if Tracker.stdout_open?(sink.tracker) do
      result = safe_output_write(sink.output_writer, sink.stdout, line)
      if result != :ok, do: Tracker.close_stdout(sink.tracker)

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, Artifact.error(:stdout, reason)}
      end
    else
      {:error, Artifact.error(:stdout, :closed)}
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

  defp sink_options(opts, artifact_io) do
    %{
      stdout: Keyword.get(opts, :output_device, :stdio),
      output_writer: Keyword.get(opts, :output_writer, &IO.write/2),
      utc_now: Keyword.get(opts, :utc_now, &DateTime.utc_now/0),
      artifact_io: artifact_io
    }
  end
end
