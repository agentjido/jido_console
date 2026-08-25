defmodule Jido.Console.Process.Store do
  @moduledoc "Persists process markers under the Jido home run directory."

  alias Jido.Console.Document
  alias Jido.Console.Home
  alias Jido.Console.Process.Contract

  @max_marker_bytes 16_384

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
  @spec put(Contract.live_record(), keyword()) :: {:ok, Contract.live_record()} | {:error, term()}
  def put(record, opts \\ []) when is_map(record) do
    identity = Contract.key(record)

    with {:ok, dir} <- ensure_run_dir(opts),
         path = Path.join(dir, filename(identity)),
         :ok <- File.write(path, Jason.encode!(encode(Contract.stored(record)))),
         :ok <- File.chmod(path, Home.file_mode()) do
      {:ok, record}
    end
  end

  @doc "Reads one process marker."
  @spec get(Contract.identity(), keyword()) :: {:ok, Contract.live_record()} | {:error, term()}
  def get(identity, opts \\ []) when is_tuple(identity) do
    with {:ok, dir} <- run_dir(opts) do
      read_file(Path.join(dir, filename(identity)))
    end
  end

  @doc "Deletes one process marker after confirmed shutdown."
  @spec delete(Contract.identity(), keyword()) :: :ok | {:error, term()}
  def delete(identity, opts \\ []) when is_tuple(identity) do
    with {:ok, dir} <- run_dir(opts) do
      case File.rm(Path.join(dir, filename(identity))) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:process_marker_delete_failed, identity, reason}}
      end
    end
  end

  @doc "Removes active markers whose recorded owner process is gone."
  @spec reap(keyword()) :: {:ok, [map()]} | {:error, term()}
  def reap(opts \\ []) do
    with {:ok, records} <- list(opts) do
      reaped =
        Enum.filter(records, fn record ->
          stale?(record) and match?(:ok, delete(Contract.key(record), opts))
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
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, decoded, _contents} <- Document.decode_file(path, max_file_bytes: @max_marker_bytes),
         {:ok, record} <- decode(decoded),
         true <- Path.basename(path) == filename(Contract.key(record)) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :process_not_found}
      {:ok, %{type: type}} -> {:error, {:process_marker_invalid, path, {:not_regular, type}}}
      false -> {:error, {:process_marker_invalid, path, :process_identity_conflict}}
      {:error, reason} -> {:error, {:process_marker_invalid, path, reason}}
    end
  end

  defp filename({kind, name}), do: "#{kind}.#{name}.json"

  defp encode(record) do
    %{
      "kind" => Atom.to_string(record.kind),
      "name" => record.name,
      "status" => Atom.to_string(record.status),
      "readiness" => record.readiness,
      "failure" => record[:failure],
      "owner_os_pid" => record[:owner_os_pid]
    }
  end

  defp decode(map) when is_map(map) do
    with {:ok, parsed} <- Zoi.parse(marker_schema(), map),
         {:ok, kind} <- existing_atom(parsed["kind"]),
         {:ok, status} <- existing_atom(parsed["status"]) do
      Contract.restore(%{
        kind: kind,
        name: parsed["name"],
        status: status,
        readiness: parsed["readiness"],
        failure: parsed["failure"],
        owner_os_pid: parsed["owner_os_pid"]
      })
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

  defp marker_schema do
    catalog = Contract.catalog()
    kinds = catalog |> Map.keys() |> Enum.map(&Atom.to_string/1)
    names = catalog |> Map.values() |> Enum.map(& &1.name)
    statuses = Enum.map(Contract.statuses(), &Atom.to_string/1)

    Zoi.map(
      %{
        "failure" => Zoi.string() |> Zoi.nullable(),
        "kind" => Zoi.enum(kinds),
        "name" => Zoi.enum(names),
        "owner_os_pid" => Zoi.integer() |> Zoi.gte(2) |> Zoi.nullable(),
        "readiness" => Zoi.string() |> Zoi.min(1),
        "status" => Zoi.enum(statuses)
      },
      unrecognized_keys: :error
    )
  end
end
