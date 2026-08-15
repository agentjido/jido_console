defmodule Jido.Console.Home do
  @moduledoc """
  Resolves the Jido home directory contract.

  `JIDO_HOME` selects the complete product home. When it is unset, the default
  is `~/.jido`. Local product paths resolve through this module unless they are
  an explicit workspace or system path.
  """

  @schema "jido.home"
  @schema_version 1
  @directory_mode 0o700
  @file_mode 0o600

  @directories %{
    state: %{
      id: :state,
      relative: "state",
      purpose: "durable product state",
      owner: :product,
      class: :retained
    },
    logs: %{
      id: :logs,
      relative: "logs",
      purpose: "diagnostic logs",
      owner: :diagnostics,
      class: :retained
    },
    artifacts: %{
      id: :artifacts,
      relative: "artifacts",
      purpose: "run artifacts",
      owner: :artifacts,
      class: :retained
    },
    cache: %{
      id: :cache,
      relative: "cache",
      purpose: "disposable cache",
      owner: :cache,
      class: :disposable
    },
    run: %{
      id: :run,
      relative: "run",
      purpose: "process-local files",
      owner: :process,
      class: :disposable
    }
  }

  @type directory_id :: :state | :logs | :artifacts | :cache | :run
  @type directory :: %{
          id: directory_id(),
          relative: String.t(),
          purpose: String.t(),
          owner: atom(),
          class: :retained | :disposable
        }
  @type t :: %{
          schema: String.t(),
          schema_version: pos_integer(),
          root: String.t(),
          source: :jido_home | :default,
          directories: %{directory_id() => directory()}
        }

  @doc "Returns the home contract schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Returns the home contract schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the required directory mode."
  @spec directory_mode() :: non_neg_integer()
  def directory_mode, do: @directory_mode

  @doc "Returns the required file mode."
  @spec file_mode() :: non_neg_integer()
  def file_mode, do: @file_mode

  @doc "Returns the stable directory contract."
  @spec directories() :: %{directory_id() => directory()}
  def directories, do: @directories

  @doc "Resolves the product home without creating directories."
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts \\ []) do
    case selected_root(opts) do
      {:ok, root, source} ->
        {:ok,
         %{
           schema: @schema,
           schema_version: @schema_version,
           root: root,
           source: source,
           directories: @directories
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Returns one named directory path under the resolved home."
  @spec path(directory_id(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def path(id, opts \\ []) when is_map_key(@directories, id) do
    with {:ok, home} <- resolve(opts) do
      {:ok, Path.join(home.root, Map.fetch!(@directories, id).relative)}
    end
  end

  @doc "Creates required directories with safe permissions."
  @spec ensure(keyword()) :: {:ok, t()} | {:error, term()}
  def ensure(opts \\ []) do
    with {:ok, home} <- resolve(opts),
         :ok <- ensure_private_directory(home.root),
         :ok <- ensure_named_directories(home) do
      {:ok, home}
    end
  end

  @doc "Returns the previous product cache root used for migration."
  @spec previous_cache_root(keyword()) :: String.t()
  def previous_cache_root(opts \\ []) do
    Keyword.get_lazy(opts, :previous_cache_root, fn ->
      :filename.basedir(:user_cache, ~c"jido") |> List.to_string()
    end)
  end

  @doc "Returns true when a path is inside the resolved product home."
  @spec in_home?(String.t(), keyword()) :: boolean()
  def in_home?(path, opts \\ []) when is_binary(path) do
    case resolve(opts) do
      {:ok, home} ->
        expanded = Path.expand(path)
        home_root = Path.expand(home.root)
        expanded == home_root or String.starts_with?(expanded, home_root <> "/")

      {:error, _reason} ->
        false
    end
  end

  @doc "Rejects a path whose mode grants group or other access."
  @spec check_private(String.t()) :: :ok | {:error, term()}
  def check_private(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, %{mode: mode}} -> {:error, {:unsafe_permissions, path, mode}}
      {:error, reason} -> {:error, {:home_stat_failed, path, reason}}
    end
  end

  defp selected_root(opts) do
    case Keyword.get_lazy(opts, :jido_home, fn -> System.get_env("JIDO_HOME") end) do
      value when is_binary(value) and value != "" ->
        validate_root(Path.expand(value), :jido_home)

      _missing ->
        user_home = Keyword.get_lazy(opts, :user_home, &System.user_home!/0)
        validate_root(Path.join(Path.expand(user_home), ".jido"), :default)
    end
  end

  defp validate_root(root, source) do
    if Path.type(root) == :absolute do
      {:ok, root, source}
    else
      {:error, {:home_root_must_be_absolute, root}}
    end
  end

  defp ensure_named_directories(home) do
    home.directories
    |> Map.values()
    |> Enum.sort_by(& &1.relative)
    |> Enum.reduce_while(:ok, fn directory, :ok ->
      path = Path.join(home.root, directory.relative)

      case ensure_private_directory(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_private_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0 do
          File.chmod(path, @directory_mode)
        else
          {:error, {:unsafe_permissions, path, mode}}
        end

      {:ok, %{type: type}} ->
        {:error, {:home_path_not_directory, path, type}}

      {:error, :enoent} ->
        create_private_directory(path)

      {:error, reason} ->
        {:error, {:home_directory_unavailable, path, reason}}
    end
  end

  defp create_private_directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %{type: :directory}} <- File.lstat(path),
         :ok <- File.chmod(path, @directory_mode) do
      :ok
    else
      {:ok, %{type: type}} -> {:error, {:home_path_not_directory, path, type}}
      {:error, reason} -> {:error, {:home_directory_unavailable, path, reason}}
    end
  end
end
