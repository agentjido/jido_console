defmodule Jido.Console.Automation.JSONL.Artifact do
  @moduledoc "Owns bounded artifact file I/O and atomic replacement."

  alias Jido.Console.Digest

  @doc "Builds and validates the injectable artifact I/O boundary."
  @spec configure(keyword()) :: {:ok, map()} | {:error, :invalid_artifact_io}
  def configure(opts) do
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

  @doc "Creates one empty output directory."
  @spec prepare_directory(String.t(), map()) :: :ok | {:error, term()}
  def prepare_directory(root, artifact_io) do
    case io_call(artifact_io, :ls, [root]) do
      {:ok, []} -> :ok
      {:ok, entries} -> {:error, {:output_directory_not_empty, root, entries}}
      {:error, :enoent} -> io_call(artifact_io, :mkdir_p, [root])
      {:error, reason} -> {:error, {:output_directory_unavailable, root, reason}}
      other -> {:error, {:output_directory_unavailable, root, other}}
    end
  end

  @doc "Creates the by-agent output directory."
  @spec prepare_agent_directory(String.t(), map()) :: :ok | {:error, term()}
  def prepare_agent_directory(root, artifact_io),
    do: io_call(artifact_io, :mkdir_p, [Path.join(root, "by-agent")])

  @doc "Writes one pretty JSON artifact with atomic replacement."
  @spec write_json(map(), String.t(), String.t(), map(), atom()) :: :ok | {:error, term()}
  def write_json(artifact_io, root, relative_path, value, phase) do
    with {:ok, json} <- Jason.encode(value, pretty: true),
         :ok <- atomic_write(artifact_io, root, relative_path, json <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, error(phase, reason)}
    end
  end

  @doc "Appends one line through atomic replacement."
  @spec append(map(), String.t(), String.t(), iodata(), atom()) :: :ok | {:error, term()}
  def append(artifact_io, root, relative_path, line, phase) do
    path = Path.join(root, relative_path)

    existing =
      case io_call(artifact_io, :read, [path]) do
        {:ok, data} when is_binary(data) -> {:ok, data}
        {:error, :enoent} -> {:ok, ""}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_artifact_read_result, other}}
      end

    with {:ok, data} <- existing,
         :ok <- atomic_write(artifact_io, root, relative_path, data <> line) do
      :ok
    else
      {:error, reason} -> {:error, error(phase, reason)}
    end
  end

  @doc "Returns a safe by-agent relative path."
  @spec agent_path(term()) :: String.t()
  def agent_path(agent_key), do: Path.join("by-agent", artifact_key(agent_key) <> ".jsonl")

  @doc "Returns an artifact error value."
  @spec error(atom(), term()) :: term()
  def error(phase, reason), do: {:automation_artifact_write_failed, phase, reason}

  @doc "Returns true for an artifact error value."
  @spec error?(term()) :: boolean()
  def error?({:automation_artifact_write_failed, _phase, _reason}), do: true
  def error?(_reason), do: false

  @doc "Returns the phase from an artifact error value."
  @spec phase(term()) :: atom()
  def phase({:automation_artifact_write_failed, phase, _reason}), do: phase

  defp atomic_write(artifact_io, root, relative_path, data) do
    path = Path.join(root, relative_path)
    temporary = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp")

    result =
      with :ok <- io_call(artifact_io, :write, [temporary, data, []]),
           :ok <- io_call(artifact_io, :chmod, [temporary, 0o600]),
           :ok <- io_call(artifact_io, :rename, [temporary, path]) do
        io_call(artifact_io, :chmod, [path, 0o600])
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        case remove_temporary(artifact_io, temporary) do
          :ok -> {:error, reason}
          {:error, cleanup_reason} -> {:error, {:artifact_write_and_cleanup_failed, reason, cleanup_reason}}
        end
    end
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

  defp artifact_key(key) when is_binary(key) do
    safe =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.replace(~r/^[.-]+|[.-]+$/, "")

    if safe != "" and safe == key do
      safe
    else
      digest = key |> Digest.hex() |> String.slice(0, 12)
      "#{if(safe == "", do: "agent", else: safe)}-#{digest}"
    end
  end
end
