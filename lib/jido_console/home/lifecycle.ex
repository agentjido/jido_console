defmodule Jido.Console.Home.Lifecycle do
  @moduledoc """
  Migration, backup, update, and removal operations for the Jido home.

  Migration copies the previous product cache into the home cache and does not
  delete the source until the destination verifies. Removal separates disposable
  cache from retained user data and requires an explicit confirmation token.
  """

  alias Jido.Console.Digest
  alias Jido.Console.Home

  @confirmation_tokens %{
    disposable: :remove_disposable,
    retained: :remove_retained_user_data
  }

  @doc "Returns the confirmation tokens required by removal."
  @spec confirmation_tokens() :: %{disposable: atom(), retained: atom()}
  def confirmation_tokens, do: @confirmation_tokens

  @doc "Copies the previous product cache into the home cache after verification."
  @spec migrate(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(opts \\ []) do
    with {:ok, home} <- Home.ensure(opts),
         {:ok, cache} <- Home.path(:cache, opts),
         source = Home.previous_cache_root(opts),
         destination = Path.join(cache, "legacy-user-cache"),
         :ok <- copy_verified(source, destination, opts) do
      {:ok,
       %{
         home: home.root,
         source: source,
         destination: destination,
         source_deleted?: false
       }}
    end
  end

  @doc "Writes a backup of retained home data to an empty destination directory."
  @spec backup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backup(destination, opts \\ []) when is_binary(destination) do
    with {:ok, home} <- Home.resolve(opts),
         :ok <- Home.check_private(home.root),
         dest = Path.expand(destination),
         :ok <- prepare_empty_directory(dest),
         retained = retained_directories(home),
         :ok <- copy_entries(home.root, dest, retained),
         :ok <- File.chmod(dest, Home.directory_mode()) do
      {:ok, %{home: home.root, destination: dest, entries: retained}}
    end
  end

  @doc "Restores retained home data from a backup directory."
  @spec restore(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore(source, opts \\ []) when is_binary(source) do
    with {:ok, home} <- Home.ensure(opts),
         src = Path.expand(source),
         {:ok, %{type: :directory}} <- File.lstat(src),
         retained = retained_directories(home),
         :ok <- copy_entries(src, home.root, retained) do
      {:ok, %{home: home.root, source: src, entries: retained}}
    else
      {:ok, %{type: type}} -> {:error, {:backup_not_directory, Path.expand(source), type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Ensures the home layout exists and does not widen permissions."
  @spec update(keyword()) :: {:ok, map()} | {:error, term()}
  def update(opts \\ []) do
    with {:ok, home} <- Home.ensure(opts),
         :ok <- Home.check_private(home.root),
         :ok <- check_named_private(home) do
      {:ok, %{home: home.root, permissions: Home.directory_mode()}}
    end
  end

  @doc """
  Removes disposable product files, or retained user data when confirmed.

  Pass `confirm: :remove_disposable` to delete cache and process-local files.
  Pass `confirm: :remove_retained_user_data` to also delete state, logs, and
  artifacts. The home root is removed only when it is empty after that work.
  """
  @spec remove(keyword()) :: {:ok, map()} | {:error, term()}
  def remove(opts \\ []) do
    with {:ok, home} <- Home.resolve(opts),
         {:ok, scope} <- removal_scope(opts),
         ids = removal_ids(home, scope),
         :ok <- remove_directories(home, ids),
         :ok <- maybe_remove_root(home.root) do
      {:ok,
       %{
         home: home.root,
         removed: Enum.map(ids, & &1.id),
         retained: retained_after(home, scope)
       }}
    end
  end

  defp removal_scope(opts) do
    case Keyword.get(opts, :confirm) do
      :remove_disposable -> {:ok, :disposable}
      :remove_retained_user_data -> {:ok, :all}
      nil -> {:error, :removal_confirmation_required}
      other -> {:error, {:invalid_removal_confirmation, other}}
    end
  end

  defp removal_ids(home, :disposable) do
    home.directories |> Map.values() |> Enum.filter(&(&1.class == :disposable))
  end

  defp removal_ids(home, :all), do: Map.values(home.directories)

  defp retained_after(home, :disposable) do
    home.directories
    |> Map.values()
    |> Enum.filter(&(&1.class == :retained))
    |> Enum.map(& &1.id)
  end

  defp retained_after(_home, :all), do: []

  defp remove_directories(home, directories) do
    Enum.reduce_while(directories, :ok, fn directory, :ok ->
      path = Path.join(home.root, directory.relative)

      case File.rm_rf(path) do
        {:ok, _paths} -> {:cont, :ok}
        {:error, reason, _file} -> {:halt, {:error, {:home_remove_failed, path, reason}}}
      end
    end)
  end

  defp maybe_remove_root(root) do
    case File.ls(root) do
      {:ok, []} ->
        case File.rmdir(root) do
          :ok -> :ok
          {:error, reason} -> {:error, {:home_remove_failed, root, reason}}
        end

      {:ok, _entries} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:home_remove_failed, root, reason}}
    end
  end

  defp retained_directories(home) do
    home.directories
    |> Map.values()
    |> Enum.filter(&(&1.class == :retained))
    |> Enum.map(& &1.relative)
    |> Enum.sort()
  end

  defp copy_verified(source, destination, opts) do
    case File.lstat(source) do
      {:ok, %{type: :directory}} ->
        verify? = Keyword.get(opts, :verify, true)

        with :ok <- copy_directory(source, destination) do
          maybe_verify(source, destination, verify?)
        end

      {:error, :enoent} ->
        :ok

      {:ok, %{type: type}} ->
        {:error, {:migration_source_not_directory, source, type}}

      {:error, reason} ->
        {:error, {:migration_source_unavailable, source, reason}}
    end
  end

  defp maybe_verify(_source, _destination, false), do: :ok

  defp maybe_verify(source, destination, verify) when is_function(verify, 2) do
    verify.(source, destination)
  end

  defp maybe_verify(source, destination, true) do
    case {inventory(source), inventory(destination)} do
      {source_files, dest_files} when source_files == dest_files -> :ok
      {source_files, dest_files} -> {:error, {:migration_verification_failed, source_files, dest_files}}
    end
  end

  defp copy_entries(from, to, relatives) do
    Enum.reduce_while(relatives, :ok, fn relative, :ok ->
      source = Path.join(from, relative)
      destination = Path.join(to, relative)

      result =
        case File.lstat(source) do
          {:ok, %{type: :directory}} -> copy_directory(source, destination)
          {:error, :enoent} -> :ok
          {:ok, %{type: type}} -> {:error, {:backup_entry_not_directory, source, type}}
          {:error, reason} -> {:error, {:backup_entry_unavailable, source, reason}}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp copy_directory(source, destination) do
    with :ok <- File.mkdir_p(destination),
         :ok <- File.chmod(destination, Home.directory_mode()) do
      case File.ls(source) do
        {:ok, names} ->
          copy_directory_entries(source, destination, Enum.sort(names))

        {:error, reason} ->
          {:error, {:home_copy_failed, source, reason}}
      end
    end
  end

  defp copy_directory_entries(source, destination, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      from = Path.join(source, name)
      to = Path.join(destination, name)

      case File.lstat(from) do
        {:ok, %{type: :directory}} ->
          halt_error(copy_directory(from, to))

        {:ok, %{type: :regular}} ->
          halt_error(copy_private_file(from, to))

        {:ok, %{type: type}} ->
          {:halt, {:error, {:unsupported_home_entry, from, type}}}

        {:error, reason} ->
          {:halt, {:error, {:home_copy_failed, from, reason}}}
      end
    end)
  end

  defp copy_private_file(from, to) do
    with :ok <- File.cp(from, to) do
      File.chmod(to, Home.file_mode())
    end
  end

  defp prepare_empty_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, []} -> :ok
          {:ok, entries} -> {:error, {:backup_destination_not_empty, path, entries}}
          {:error, reason} -> {:error, {:backup_destination_unavailable, path, reason}}
        end

      {:ok, %{type: type}} ->
        {:error, {:backup_destination_not_directory, path, type}}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path) do
          File.chmod(path, Home.directory_mode())
        end

      {:error, reason} ->
        {:error, {:backup_destination_unavailable, path, reason}}
    end
  end

  defp inventory(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      digest =
        case Digest.file(path) do
          {:ok, value} -> value
          {:error, reason} -> {:error, reason}
        end

      {Path.relative_to(path, root), digest}
    end)
  end

  defp check_named_private(home) do
    home.directories
    |> Map.values()
    |> Enum.reduce_while(:ok, fn directory, :ok ->
      path = Path.join(home.root, directory.relative)

      case Home.check_private(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp halt_error(:ok), do: {:cont, :ok}
  defp halt_error({:error, _reason} = error), do: {:halt, error}
end
