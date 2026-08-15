defmodule Jido.Console.Process.Store do
  @moduledoc "Persists process markers under the Jido home run directory."

  alias Jido.Console.Home

  @doc "Lists stored process markers."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, dir} <- run_dir(opts),
         {:ok, names} <- list_files(dir) do
      records =
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          case read_file(Path.join(dir, name)) do
            {:ok, record} -> [record]
            {:error, _reason} -> []
          end
        end)

      {:ok, records}
    end
  end

  @doc "Writes one process marker."
  @spec put(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(record, opts \\ []) when is_map(record) do
    with {:ok, dir} <- ensure_run_dir(opts),
         path = Path.join(dir, filename(record.id)),
         :ok <- File.write(path, Jason.encode!(encode(record))),
         :ok <- File.chmod(path, Home.file_mode()) do
      {:ok, record}
    end
  end

  @doc "Reads one process marker."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(id, opts \\ []) when is_binary(id) do
    with {:ok, dir} <- run_dir(opts) do
      read_file(Path.join(dir, filename(id)))
    end
  end

  @doc "Deletes one process marker after confirmed shutdown."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts \\ []) when is_binary(id) do
    with {:ok, dir} <- run_dir(opts) do
      case File.rm(Path.join(dir, filename(id))) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:process_marker_delete_failed, id, reason}}
      end
    end
  end

  @doc "Removes active markers whose recorded owner process is gone."
  @spec reap(keyword()) :: {:ok, [map()]} | {:error, term()}
  def reap(opts \\ []) do
    with {:ok, records} <- list(opts) do
      reaped =
        Enum.filter(records, fn record ->
          stale?(record) and match?(:ok, delete(record.id, opts))
        end)

      {:ok, reaped}
    end
  end

  defp stale?(record) do
    record.status in [:starting, :ready, :running] and not owner_alive?(record)
  end

  defp owner_alive?(%{owner_pid: pid}) when is_pid(pid), do: Elixir.Process.alive?(pid)

  defp owner_alive?(%{owner_os_pid: os_pid}) when is_integer(os_pid) and os_pid > 1 do
    Jido.Console.Process.Tree.alive?(os_pid)
  end

  defp owner_alive?(_record), do: false

  defp run_dir(opts) do
    Home.path(:run, opts)
  end

  defp ensure_run_dir(opts) do
    with {:ok, _home} <- Home.ensure(opts) do
      Home.path(:run, opts)
    end
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, Enum.filter(names, &String.ends_with?(&1, ".json"))}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:process_store_unavailable, dir, reason}}
    end
  end

  defp read_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, record} <- decode(decoded) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :process_not_found}
      {:error, reason} -> {:error, {:process_marker_invalid, path, reason}}
    end
  end

  defp filename(id), do: "#{id}.json"

  defp encode(record) do
    %{
      "id" => record.id,
      "kind" => Atom.to_string(record.kind),
      "name" => record.name,
      "owner" => record.owner,
      "status" => Atom.to_string(record.status),
      "readiness" => record.readiness,
      "failure" => record[:failure],
      "owner_os_pid" => record[:owner_os_pid]
    }
  end

  defp decode(map) when is_map(map) do
    with {:ok, kind} <- existing_atom(Map.get(map, "kind")),
         {:ok, status} <- existing_atom(Map.get(map, "status")),
         id when is_binary(id) and id != "" <- Map.get(map, "id"),
         name when is_binary(name) <- Map.get(map, "name"),
         owner when is_binary(owner) <- Map.get(map, "owner"),
         readiness when is_binary(readiness) <- Map.get(map, "readiness") do
      {:ok,
       %{
         id: id,
         kind: kind,
         name: name,
         owner: owner,
         status: status,
         readiness: readiness,
         failure: Map.get(map, "failure"),
         owner_pid: nil,
         owner_os_pid: os_pid(Map.get(map, "owner_os_pid"))
       }}
    else
      _invalid -> {:error, :invalid_process_marker}
    end
  end

  defp decode(_other), do: {:error, :invalid_process_marker}

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(_value), do: :error

  defp os_pid(value) when is_integer(value) and value > 1, do: value
  defp os_pid(_value), do: nil
end
