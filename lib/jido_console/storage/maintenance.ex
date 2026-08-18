defmodule Jido.Console.Storage.Maintenance do
  @moduledoc "Crash-safe owner for stopped-store maintenance manifests."

  use GenServer

  alias Jido.Console.Home
  alias Jido.Console.Session.Durable.CanonicalJSON

  @max_bytes 64 * 1_024

  @doc "Starts the maintenance owner and reconciles an incomplete manifest."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Writes one prepared stopped-store operation manifest."
  @spec prepare(GenServer.server(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(server \\ __MODULE__, operation_id, kind, details \\ %{}) do
    GenServer.call(server, {:prepare, operation_id, kind, details})
  end

  @doc "Completes and removes the exact prepared manifest."
  @spec complete(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def complete(server \\ __MODULE__, operation_id), do: GenServer.call(server, {:complete, operation_id})

  @doc "Returns the current manifest or nil."
  @spec current(GenServer.server()) :: {:ok, map() | nil}
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @impl true
  def init(opts) do
    with {:ok, path} <- manifest_path(opts),
         :ok <- validate_path(path),
         {:ok, manifest} <- reconcile(path) do
      {:ok, %{path: path, manifest: manifest, writer: Keyword.get(opts, :writer)}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:prepare, operation_id, kind, details}, _from, %{manifest: nil} = state)
      when is_binary(operation_id) and operation_id != "" and is_binary(kind) and kind != "" and is_map(details) do
    if writer_available?(state.writer) do
      {:reply, {:error, :storage_writer_must_be_stopped}, state}
    else
      manifest = %{
        "schema" => "jido.storage-maintenance",
        "schema_version" => 1,
        "operation_id" => operation_id,
        "kind" => kind,
        "state" => "prepared",
        "details" => details
      }

      case write_manifest(state.path, manifest) do
        :ok -> {:reply, {:ok, manifest}, %{state | manifest: manifest}}
        {:error, _reason} = error -> {:reply, error, state}
      end
    end
  end

  def handle_call({:prepare, _operation_id, _kind, _details}, _from, %{manifest: nil} = state),
    do: {:reply, {:error, :invalid_maintenance_operation}, state}

  def handle_call({:prepare, _operation_id, _kind, _details}, _from, state),
    do: {:reply, {:error, :maintenance_operation_active}, state}

  def handle_call({:complete, operation_id}, _from, %{manifest: %{"operation_id" => operation_id}} = state) do
    case remove_manifest(state.path) do
      :ok -> {:reply, :ok, %{state | manifest: nil}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:complete, operation_id}, _from, state),
    do: {:reply, {:error, {:maintenance_operation_not_found, operation_id}}, state}

  def handle_call(:current, _from, state), do: {:reply, {:ok, state.manifest}, state}

  defp manifest_path(opts) do
    home_opts = Keyword.take(opts, [:jido_home, :user_home])

    with {:ok, _home} <- Home.ensure(home_opts),
         {:ok, state} <- Home.path(:state, home_opts) do
      {:ok, Path.join([state, "sessions", "v1", "maintenance.json"])}
    end
  end

  defp validate_path(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), Home.directory_mode()) do
      case File.lstat(path) do
        {:ok, %{type: :regular}} -> Home.check_private(path)
        {:ok, %{type: type}} -> {:error, {:unsafe_maintenance_manifest, path, type}}
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:maintenance_manifest_unavailable, path, reason}}
      end
    end
  end

  defp reconcile(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes ->
        with {:ok, manifest} <- CanonicalJSON.decode(bytes),
             :ok <- validate_manifest(manifest),
             :ok <- remove_manifest(path) do
          {:ok, nil}
        end

      {:ok, bytes} ->
        {:error, {:maintenance_manifest_too_large, byte_size(bytes), @max_bytes}}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:maintenance_manifest_read_failed, path, reason}}
    end
  end

  defp validate_manifest(%{
         "schema" => "jido.storage-maintenance",
         "schema_version" => 1,
         "operation_id" => operation_id,
         "kind" => kind,
         "state" => "prepared",
         "details" => details
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(kind) and kind != "" and is_map(details),
       do: :ok

  defp validate_manifest(_manifest), do: {:error, :invalid_maintenance_manifest}

  defp write_manifest(path, manifest) do
    with {:ok, bytes} <- CanonicalJSON.encode(manifest),
         :ok <- enforce_size(bytes),
         temp = path <> ".tmp",
         :ok <- write_synced(temp, bytes),
         :ok <- File.rename(temp, path) do
      sync_parent(path)
    end
  end

  defp enforce_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp enforce_size(bytes), do: {:error, {:maintenance_manifest_too_large, byte_size(bytes), @max_bytes}}

  defp write_synced(path, bytes) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]),
         :ok <- File.chmod(path, Home.file_mode()),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      :ok
    else
      {:error, :eexist} ->
        with :ok <- File.rm(path), do: write_synced(path, bytes)

      {:error, reason} ->
        {:error, {:maintenance_manifest_write_failed, path, reason}}
    end
  end

  defp remove_manifest(path) do
    case File.rm(path) do
      :ok -> sync_parent(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:maintenance_manifest_remove_failed, path, reason}}
    end
  end

  defp sync_parent(path) do
    case :file.open(Path.dirname(path) |> String.to_charlist(), [:read, :raw, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        :ok = :file.close(io)
        result

      {:error, reason} ->
        {:error, {:maintenance_parent_sync_failed, Path.dirname(path), reason}}
    end
  end

  defp writer_available?(nil), do: false
  defp writer_available?(writer), do: not is_nil(GenServer.whereis(writer))
end
