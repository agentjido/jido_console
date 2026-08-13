defmodule Jido.Cli.LocalCoding.MutationBackend do
  @moduledoc false

  @behaviour Jidoka.CodingPack.MutationBackend

  alias Jidoka.CodingPack.{Ignore, Workspace}
  alias Jidoka.ExecutionEnvironment.{Checkpoint, EnforcementEvidence}

  @adapter_id "jido_cli.local_folder"
  @max_checkpoint_bytes 16 * 1_024 * 1_024
  @max_session_checkpoint_bytes 64 * 1_024 * 1_024
  @max_session_checkpoints 16

  @impl true
  def checkpoint(workspace, opts) do
    reference = "local-checkpoint-#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, snapshot, snapshot_bytes} <- snapshot(workspace),
         :ok <- store_snapshot(state(opts), reference, snapshot, snapshot_bytes) do
      checkpoint =
        Checkpoint.new!(
          checkpoint_ref: reference,
          binding_revision: 0,
          profile_digest: Keyword.fetch!(opts, :profile_digest),
          evidence_digest: digest(snapshot),
          preserves: %{"files" => true},
          forkable: false,
          created_at_ms: System.system_time(:millisecond)
        )

      {:ok, checkpoint, evidence(:checkpoint)}
    end
  end

  @impl true
  def inspect_file(workspace, relative, _opts) do
    with {:ok, resolved} <- Workspace.resolve(workspace, relative, allow_missing: true) do
      case File.read(resolved.absolute) do
        {:ok, content} ->
          {:ok,
           %{
             exists?: true,
             content: content,
             sha256: digest(content),
             size: byte_size(content)
           }, evidence(:read)}

        {:error, :enoent} ->
          {:ok, %{exists?: false, content: nil, sha256: nil, size: 0}, evidence(:read)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def replace_file(workspace, relative, content, _opts) do
    with {:ok, resolved} <- Workspace.resolve(workspace, relative, allow_missing: true),
         :ok <- File.mkdir_p(Path.dirname(resolved.absolute)),
         temporary = resolved.absolute <> ".jido-#{System.unique_integer([:positive, :monotonic])}",
         :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.rename(temporary, resolved.absolute) do
      final_state = %{
        exists?: true,
        content: content,
        sha256: digest(content),
        size: byte_size(content)
      }

      {:ok, %{method: :atomic_replace, final_state: final_state}, evidence(:write)}
    end
  end

  @impl true
  def restore(workspace, checkpoint, opts) do
    case Agent.get(state(opts), &get_in(&1, [:snapshots, checkpoint.checkpoint_ref])) do
      snapshot when is_map(snapshot) -> restore_snapshot(workspace, snapshot)
      _missing -> {:error, :checkpoint_not_found}
    end
  end

  defp snapshot(workspace) do
    case walk_directory(workspace, ".", %{}, 0, 0) do
      {:ok, files, _file_count, total_bytes} -> {:ok, files, total_bytes}
      {:error, _reason} = error -> error
    end
  end

  defp walk_directory(workspace, relative, files, file_count, total_bytes) do
    directory = if relative == ".", do: workspace.root, else: Path.join(workspace.root, relative)

    with {:ok, entries} <- File.ls(directory) do
      entries
      |> Enum.sort()
      |> Enum.reduce_while({:ok, files, file_count, total_bytes}, fn entry, {:ok, files, file_count, total_bytes} ->
        child = if relative == ".", do: entry, else: Path.join(relative, entry)

        case snapshot_entry(workspace, child, files, file_count, total_bytes) do
          {:ok, next_files, next_count, next_bytes} ->
            {:cont, {:ok, next_files, next_count, next_bytes}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp snapshot_entry(workspace, relative, files, file_count, total_bytes) do
    with {:ok, %{ignored?: false}} <- Ignore.decision(workspace, relative),
         {:ok, stat} <- File.lstat(Path.join(workspace.root, relative)) do
      snapshot_type(stat.type, workspace, relative, files, file_count, total_bytes)
    else
      {:ok, %{ignored?: true}} -> {:ok, files, file_count, total_bytes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_type(:directory, workspace, relative, files, file_count, total_bytes),
    do: walk_directory(workspace, relative, files, file_count, total_bytes)

  defp snapshot_type(:regular, workspace, relative, files, file_count, total_bytes) do
    with :ok <- checkpoint_file_count(file_count + 1, workspace),
         {:ok, content} <- File.read(Path.join(workspace.root, relative)),
         :ok <- checkpoint_size(total_bytes + byte_size(content)) do
      {:ok, Map.put(files, relative, content), file_count + 1, total_bytes + byte_size(content)}
    end
  end

  defp snapshot_type(_type, _workspace, _relative, files, file_count, total_bytes),
    do: {:ok, files, file_count, total_bytes}

  defp checkpoint_file_count(count, workspace) do
    if count <= workspace.limits.max_search_files,
      do: :ok,
      else: {:error, :checkpoint_file_limit_exceeded}
  end

  defp checkpoint_size(bytes) do
    if bytes <= @max_checkpoint_bytes,
      do: :ok,
      else: {:error, :checkpoint_size_limit_exceeded}
  end

  defp store_snapshot(state, reference, snapshot, snapshot_bytes) do
    Agent.get_and_update(state, fn current ->
      count = map_size(current.snapshots)
      next_bytes = current.snapshot_bytes + snapshot_bytes

      if count < @max_session_checkpoints and next_bytes <= @max_session_checkpoint_bytes do
        next = %{
          current
          | snapshots: Map.put(current.snapshots, reference, snapshot),
            snapshot_bytes: next_bytes
        }

        {:ok, next}
      else
        {{:error, :checkpoint_session_limit_exceeded}, current}
      end
    end)
  end

  defp restore_snapshot(workspace, snapshot) do
    with {:ok, current, _snapshot_bytes} <- snapshot(workspace),
         :ok <- remove_created_files(workspace, Map.keys(current) -- Map.keys(snapshot)),
         :ok <- write_snapshot(workspace, snapshot) do
      {:ok, evidence(:write)}
    end
  end

  defp remove_created_files(workspace, paths) do
    Enum.reduce_while(paths, :ok, fn relative, :ok ->
      case Workspace.resolve(workspace, relative) do
        {:ok, resolved} ->
          case File.rm(resolved.absolute) do
            :ok -> {:cont, :ok}
            {:error, :enoent} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp write_snapshot(workspace, snapshot) do
    Enum.reduce_while(snapshot, :ok, fn {relative, content}, :ok ->
      with {:ok, resolved} <- Workspace.resolve(workspace, relative, allow_missing: true),
           :ok <- File.mkdir_p(Path.dirname(resolved.absolute)),
           :ok <- File.write(resolved.absolute, content, [:binary]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp evidence(operation) do
    EnforcementEvidence.new!(
      status: :confirmed,
      adapter_id: @adapter_id,
      backend: "local-process",
      isolation: :process,
      network: :disabled,
      workspace: :persistent,
      observed_at_ms: System.system_time(:millisecond),
      facts: %{
        "path_confined" => true,
        "checkpoint" => true,
        "filesystem_read" => true,
        "filesystem_write" => true,
        "atomic_replace" => true,
        "operation" => Atom.to_string(operation)
      }
    )
  end

  defp state(opts), do: Keyword.fetch!(opts, :state)

  defp digest(value) when is_binary(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp digest(value), do: value |> :erlang.term_to_binary([:deterministic]) |> digest()
end
