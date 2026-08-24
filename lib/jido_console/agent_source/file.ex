defmodule Jido.Console.AgentSource.File do
  @moduledoc """
  Bounded admission for local JSON and YAML agent files.

  The loader rejects a direct symbolic link and compares path and handle
  metadata before and after one bounded read. OTP does not expose an
  `O_NOFOLLOW` or read-only nonblocking file-open option here. A same-host
  replacement after the final metadata check can still substitute a FIFO. OTP
  can leave that pending open below the killed worker until a writer arrives.
  A same-inode write that does not change observable metadata also cannot be
  proved absent by these checks. These residual races are accepted for the
  pure-Elixir loader and must not be treated as verified file identity.
  """

  alias Jido.Console.AgentSource.Admission
  alias Jido.Console.AgentSource.Record
  alias Jido.Console.Digest

  @max_bytes 1_000_000
  @deadline_ms 5_000
  @max_heap_bytes 64 * 1_024 * 1_024
  @max_symlink_hops 40

  @type format :: :json | :yaml

  @doc false
  @spec resolve(String.t(), format(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def resolve(source, format, opts)
      when is_binary(source) and format in [:json, :yaml] and is_list(opts) do
    deadline_ms = bounded_positive(opts[:deadline_ms], @deadline_ms)
    max_heap_bytes = bounded_positive(opts[:worker_max_heap_bytes], @max_heap_bytes)
    run_worker(fn -> load(source, format, opts) end, deadline_ms, max_heap_bytes)
  end

  defp run_worker(fun, deadline_ms, max_heap_bytes) do
    parent = self()
    result_tag = make_ref()
    heap_words = max(div(max_heap_bytes, :erlang.system_info(:wordsize)), 1_024)

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(parent, {result_tag, protected(fun)}) end,
        [
          :monitor,
          {:message_queue_data, :off_heap},
          {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}
        ]
      )

    timer = Process.send_after(self(), {:agent_source_deadline, result_tag}, deadline_ms)

    receive do
      {^result_tag, result} ->
        Process.cancel_timer(timer)
        Process.demonitor(monitor, [:flush])
        flush_deadline(result_tag)
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        Process.cancel_timer(timer)
        flush_deadline(result_tag)
        {:error, :agent_source_heap_limit_exceeded}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        Process.cancel_timer(timer)
        flush_deadline(result_tag)
        {:error, :agent_source_admission_failed}

      {:agent_source_deadline, ^result_tag} ->
        Process.exit(pid, :kill)
        await_down(monitor, pid)
        {:error, :agent_source_deadline_exceeded}
    end
  end

  defp protected(fun) do
    fun.()
  rescue
    _exception -> {:error, :agent_source_admission_failed}
  catch
    _kind, _reason -> {:error, :agent_source_admission_failed}
  end

  defp flush_deadline(result_tag) do
    receive do
      {:agent_source_deadline, ^result_tag} -> :ok
    after
      0 -> :ok
    end
  end

  defp await_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp load(source, format, opts) do
    with {:ok, startup_cwd} <- startup_cwd(opts),
         {:ok, source_path} <- source_path(source, startup_cwd),
         {:ok, source_stat} <- direct_regular_lstat(source_path),
         {:ok, canonical_path} <- canonical_path(source_path),
         {:ok, canonical_stat} <- direct_regular_lstat(canonical_path),
         :ok <- same_file(source_stat, canonical_stat),
         :ok <- invoke_hook(opts, :after_lstat, canonical_path, canonical_stat),
         {:ok, preopen_stat} <- direct_regular_lstat(canonical_path),
         :ok <- same_snapshot(canonical_stat, preopen_stat),
         {:ok, device} <- open(canonical_path) do
      try do
        load_open_file(
          device,
          source_path,
          canonical_path,
          source_stat,
          canonical_stat,
          format,
          opts
        )
      after
        _result = File.close(device)
      end
    end
  end

  defp load_open_file(
         device,
         source_path,
         canonical_path,
         source_stat,
         canonical_stat,
         format,
         opts
       ) do
    with :ok <- invoke_hook(opts, :after_open, canonical_path, device),
         {:ok, handle_stat} <- handle_stat(device),
         :ok <- same_file(source_stat, handle_stat),
         :ok <- same_snapshot(canonical_stat, handle_stat),
         :ok <- invoke_hook(opts, :before_read, canonical_path, device),
         {:ok, bytes} <- bounded_read(device),
         :ok <- validate_size(bytes, handle_stat),
         :ok <- validate_utf8(bytes),
         :ok <- invoke_hook(opts, :after_read, canonical_path, bytes),
         {:ok, final_source_stat} <- direct_regular_lstat(source_path),
         {:ok, final_canonical_stat} <- direct_regular_lstat(canonical_path),
         :ok <- same_snapshot(source_stat, final_source_stat),
         :ok <- same_snapshot(canonical_stat, final_canonical_stat),
         :ok <- same_snapshot(handle_stat, final_canonical_stat),
         {:ok, spec} <- Admission.admit(bytes, format, admission_opts(opts)) do
      {:ok, record(spec, canonical_path, handle_stat, format, bytes)}
    end
  end

  defp startup_cwd(opts) do
    case Keyword.fetch(opts, :startup_cwd) do
      {:ok, cwd} when is_binary(cwd) and cwd != "" -> {:ok, Path.expand(cwd)}
      {:ok, _cwd} -> {:error, :invalid_startup_cwd}
      :error -> {:ok, File.cwd!()}
    end
  end

  defp source_path(source, startup_cwd) do
    cond do
      source == "" -> {:error, :invalid_agent_source}
      not String.valid?(source) -> {:error, :invalid_agent_source}
      true -> {:ok, Path.expand(source, startup_cwd)}
    end
  end

  defp direct_regular_lstat(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :agent_source_symlink}
      {:ok, %File.Stat{}} -> {:error, :agent_source_not_regular}
      {:error, :enoent} -> {:error, :agent_source_missing}
      {:error, _reason} -> {:error, :agent_source_unavailable}
    end
  end

  defp canonical_path(source_path) do
    parent = Path.dirname(source_path)

    with {:ok, canonical_parent} <- resolve_symlinks(parent, MapSet.new(), 0) do
      {:ok, Path.join(canonical_parent, Path.basename(source_path))}
    end
  end

  defp resolve_symlinks(_path, _seen, hops) when hops > @max_symlink_hops,
    do: {:error, :agent_source_unavailable}

  defp resolve_symlinks(path, seen, hops) do
    path = Path.expand(path)
    [root | segments] = Path.split(path)
    walk_segments(root, segments, [], seen, hops)
  end

  defp walk_segments(current, [], _remaining, _seen, _hops), do: {:ok, current}

  defp walk_segments(current, [segment | rest], _remaining, seen, hops) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} ->
        if MapSet.member?(seen, candidate) do
          {:error, :agent_source_unavailable}
        else
          with {:ok, target} <- File.read_link(candidate) do
            target_path =
              if Path.type(target) == :absolute,
                do: target,
                else: Path.expand(target, Path.dirname(candidate))

            combined = Enum.reduce(rest, target_path, &Path.join(&2, &1))
            resolve_symlinks(combined, MapSet.put(seen, candidate), hops + 1)
          else
            {:error, _reason} -> {:error, :agent_source_unavailable}
          end
        end

      {:ok, %File.Stat{type: :directory}} ->
        walk_segments(candidate, rest, [], seen, hops)

      {:ok, %File.Stat{}} ->
        {:error, :agent_source_unavailable}

      {:error, _reason} ->
        {:error, :agent_source_unavailable}
    end
  end

  defp open(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} -> {:ok, device}
      {:error, :enoent} -> {:error, :agent_source_missing}
      {:error, _reason} -> {:error, :agent_source_unavailable}
    end
  end

  defp handle_stat(device) do
    case :file.read_file_info(device, time: :posix) do
      {:ok, record} ->
        case File.Stat.from_record(record) do
          %File.Stat{type: :regular} = stat -> {:ok, stat}
          %File.Stat{} -> {:error, :agent_source_not_regular}
        end

      {:error, _reason} ->
        {:error, :agent_source_unavailable}
    end
  end

  defp bounded_read(device) do
    case IO.binread(device, @max_bytes + 1) do
      :eof -> {:ok, ""}
      {:error, _reason} -> {:error, :agent_source_unavailable}
      bytes when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      _bytes -> {:error, :agent_source_too_large}
    end
  end

  defp validate_size(bytes, %File.Stat{size: size}) when byte_size(bytes) == size, do: :ok
  defp validate_size(_bytes, _stat), do: {:error, :agent_source_changed}

  defp validate_utf8(bytes) do
    if String.valid?(bytes), do: :ok, else: {:error, :agent_source_invalid_utf8}
  end

  defp same_file(left, right) do
    if identity(left) == identity(right), do: :ok, else: {:error, :agent_source_changed}
  end

  defp same_snapshot(left, right) do
    if snapshot(left) == snapshot(right), do: :ok, else: {:error, :agent_source_changed}
  end

  defp identity(%File.Stat{} = stat) do
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp snapshot(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.size, stat.mtime, stat.ctime, stat.mode}
  end

  defp invoke_hook(opts, name, path, value) do
    hooks = Keyword.get(opts, :file_hooks, [])

    case Keyword.get(hooks, name) do
      nil ->
        :ok

      hook when is_function(hook, 2) ->
        _result = hook.(path, value)
        :ok

      _hook ->
        {:error, :invalid_agent_source_hook}
    end
  end

  defp admission_opts(opts), do: Keyword.take(opts, [:before_import])

  defp record(spec, canonical_path, stat, format, bytes) do
    base_spec_digest = Digest.semantic(:agent_base_spec, Jidoka.project(spec))

    Record.build(
      base_spec: spec,
      identity: %{
        path: canonical_path,
        major_device: stat.major_device,
        minor_device: stat.minor_device,
        inode: stat.inode
      },
      kind: :file,
      format: format,
      byte_size: byte_size(bytes),
      digest: Digest.portable(bytes),
      base_spec_digest: base_spec_digest,
      agent_id: spec.id,
      label: safe_label(canonical_path)
    )
  end

  defp safe_label(path) do
    label =
      path
      |> Path.basename()
      |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "?")
      |> String.graphemes()
      |> Enum.take(80)
      |> Enum.join()

    if label == "", do: "agent file", else: label
  end

  defp bounded_positive(value, default) when is_integer(value) and value > 0,
    do: min(value, default)

  defp bounded_positive(_value, default), do: default
end
