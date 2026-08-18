defmodule Jido.Console.Storage.HomeLock do
  @moduledoc "Exclusive process-lifetime lock for one writable Jido home."

  use GenServer

  alias Exqlite.Sqlite3
  alias Jido.Console.Home

  @doc "Starts and holds the home lock until this process stops."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    with {:ok, path} <- lock_path(opts),
         :ok <- prepare(path),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(conn, 0),
         :ok <- acquire(conn, path),
         :ok <- File.chmod(path, Home.file_mode()),
         :ok <- protect_lock_files(path) do
      {:ok, %{conn: conn, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    _ = Sqlite3.execute(conn, "ROLLBACK")
    Sqlite3.close(conn)
  end

  defp lock_path(opts) do
    with {:ok, _home} <- Home.ensure(Keyword.take(opts, [:jido_home, :user_home])),
         {:ok, state} <- Home.path(:state, Keyword.take(opts, [:jido_home, :user_home])) do
      {:ok, Path.join([state, "sessions", "v1", "home-lock.sqlite3"])}
    end
  end

  defp prepare(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), Home.directory_mode()) do
      case File.lstat(path) do
        {:ok, %{type: :regular}} -> Home.check_private(path)
        {:ok, %{type: type}} -> {:error, {:unsafe_home_lock, path, type}}
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:home_lock_unavailable, path, reason}}
      end
    end
  end

  defp acquire(conn, path) do
    case Sqlite3.execute(conn, "BEGIN EXCLUSIVE") do
      :ok -> :ok
      {:error, reason} when reason in ["database is locked", "database is busy"] -> {:error, {:home_locked, path}}
      {:error, reason} -> {:error, {:home_lock_failed, path, reason}}
    end
  end

  defp protect_lock_files(path) do
    [path, path <> "-journal", path <> "-wal", path <> "-shm"]
    |> Enum.reduce_while(:ok, fn owned_path, :ok ->
      case File.lstat(owned_path) do
        {:ok, %{type: :regular}} ->
          with :ok <- File.chmod(owned_path, Home.file_mode()),
               :ok <- Home.check_private(owned_path) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {:home_lock_permission_failed, owned_path, reason}}}
          end

        {:ok, %{type: type}} ->
          {:halt, {:error, {:unsafe_home_lock, owned_path, type}}}

        {:error, :enoent} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:home_lock_unavailable, owned_path, reason}}}
      end
    end)
  end
end
