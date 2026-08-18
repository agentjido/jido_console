defmodule Jido.Console.Storage.Quota.Journal do
  @moduledoc false

  alias Jido.Console.Home
  alias Jido.Console.Session.Durable.CanonicalJSON

  @filename "quota-reservations.json"
  @max_bytes 1_024 * 1_024

  @doc "Loads the private quota journal and removes an incomplete temporary replacement."
  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(root) do
    path = Path.join(root, @filename)

    with :ok <- prepare(path),
         :ok <- discard_incomplete(path <> ".tmp") do
      read(path)
    end
  end

  @doc "Atomically writes and syncs the bounded private quota journal."
  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(root, journal) do
    path = Path.join(root, @filename)

    with :ok <- prepare(path),
         {:ok, bytes} <- CanonicalJSON.encode(journal),
         :ok <- enforce_size(bytes),
         :ok <- replace(path, bytes) do
      sync_parent(path)
    end
  end

  defp prepare(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), Home.directory_mode()),
         :ok <- validate_owned_file(path) do
      validate_owned_file(path <> ".tmp")
    end
  end

  defp validate_owned_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> Home.check_private(path)
      {:ok, %{type: type}} -> {:error, {:unsafe_quota_journal, path, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:quota_journal_unavailable, path, reason}}
    end
  end

  defp discard_incomplete(path) do
    case File.rm(path) do
      :ok -> sync_parent(path)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:quota_journal_remove_failed, path, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> CanonicalJSON.decode(bytes)
      {:ok, bytes} -> {:error, {:quota_journal_too_large, byte_size(bytes), @max_bytes}}
      {:error, :enoent} -> {:ok, empty()}
      {:error, reason} -> {:error, {:quota_journal_read_failed, path, reason}}
    end
  end

  defp empty do
    %{
      "schema" => "jido.storage-quota",
      "schema_version" => 1,
      "active" => [],
      "operations" => []
    }
  end

  defp enforce_size(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp enforce_size(bytes), do: {:error, {:quota_journal_too_large, byte_size(bytes), @max_bytes}}

  defp replace(path, bytes) do
    temp = path <> ".tmp"

    with :ok <- discard_incomplete(temp),
         :ok <- write_synced(temp, bytes) do
      File.rename(temp, path)
    end
  end

  defp write_synced(path, bytes) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]),
         :ok <- File.chmod(path, Home.file_mode()),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      :ok
    else
      {:error, reason} -> {:error, {:quota_journal_write_failed, path, reason}}
    end
  end

  defp sync_parent(path) do
    directory = Path.dirname(path)

    case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        :ok = :file.close(io)
        result

      {:error, reason} ->
        {:error, {:quota_journal_parent_sync_failed, directory, reason}}
    end
  end
end
