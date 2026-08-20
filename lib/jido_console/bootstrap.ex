defmodule Jido.Console.Bootstrap do
  @moduledoc "Secure runtime startup for the escript and packaged CLI."

  @marker ".complete"
  @optional_native_filter :jido_console_optional_native_load
  @on_load_warning_format ~c"The on_load function for module ~s returned:~n~P\n"

  alias Jido.Console.Digest

  @doc "Makes bundled private files available and starts the CLI applications."
  @spec start_applications(keyword()) :: :ok | {:error, term()}
  def start_applications(opts \\ []) do
    ensure_started = Keyword.get(opts, :ensure_all_started, &Application.ensure_all_started/1)

    with :ok <- install_optional_native_filter(opts),
         :ok <- make_priv_files_accessible(opts),
         {:ok, _applications} <- ensure_started.(:jido_console) do
      :ok
    end
  end

  @doc false
  @spec filter_optional_native_load(map(), term()) :: :stop | :ignore
  def filter_optional_native_load(
        %{
          level: :warning,
          msg:
            {:report,
             %{
               label: {:error_logger, :warning_msg},
               format: @on_load_warning_format,
               args: [ExtractousEx.Native | _rest]
             }}
        },
        _config
      ),
      do: :stop

  def filter_optional_native_load(_event, _config), do: :ignore

  @doc false
  @spec make_priv_files_accessible(keyword()) :: :ok | {:error, term()}
  def make_priv_files_accessible(opts \\ []) do
    priv_dir = Keyword.get(opts, :priv_dir, &:code.priv_dir/1)

    case priv_dir.(:time_zone_info) do
      path when is_list(path) ->
        if path |> List.to_string() |> File.dir?(), do: :ok, else: extract_escript(opts)

      _other ->
        extract_escript(opts)
    end
  end

  defp extract_escript(opts) do
    script = Keyword.get(opts, :script_name, fn -> :escript.script_name() |> List.to_string() end).()

    with {:ok, digest} <- file_digest(script),
         {:ok, cache_root} <- cache_root(opts),
         cache = cache_path(cache_root, digest, opts),
         {:ok, ebin_paths} <- ensure_extracted(script, cache_root, cache, digest, opts) do
      Enum.each(ebin_paths, &:code.add_patha(String.to_charlist(&1)))
      :ok
    end
  end

  defp cache_root(opts) do
    with {:ok, root} <- resolved_cache_root(opts),
         :ok <- ensure_private_directory(root),
         escript_root = Path.join(root, "escript"),
         :ok <- ensure_private_directory(escript_root) do
      {:ok, escript_root}
    end
  end

  defp resolved_cache_root(opts) do
    case Keyword.fetch(opts, :cache_root) do
      {:ok, root} ->
        {:ok, root}

      :error ->
        with {:ok, _home} <- Jido.Console.Home.ensure(opts) do
          Jido.Console.Home.path(:cache, opts)
        end
    end
  end

  defp cache_path(root, digest, opts) do
    version = Keyword.get(opts, :version, Jido.Console.Version.current())
    otp = Keyword.get(opts, :otp_release, :erlang.system_info(:otp_release)) |> to_string()
    Path.join(root, "#{version}-otp-#{otp}-#{digest}")
  end

  defp ensure_extracted(script, cache_root, cache, digest, opts) do
    case validate_cache(cache, digest) do
      {:error, :escript_cache_missing} ->
        with :ok <- report_progress(opts, :extracting_escript) do
          extract_atomically(script, cache_root, cache, digest, opts)
        end

      result ->
        result
    end
  end

  defp report_progress(opts, event) do
    case Keyword.get(opts, :progress) do
      nil ->
        :ok

      progress when is_function(progress, 1) ->
        progress.(event)
        :ok

      _progress ->
        {:error, :invalid_bootstrap_progress}
    end
  end

  defp install_optional_native_filter(opts) do
    add_filter = Keyword.get(opts, :add_primary_logger_filter, &:logger.add_primary_filter/2)
    filter = {&__MODULE__.filter_optional_native_load/2, nil}

    case add_filter.(@optional_native_filter, filter) do
      :ok -> :ok
      {:error, {:already_exist, @optional_native_filter}} -> :ok
      {:error, reason} -> {:error, {:logger_filter_install_failed, reason}}
    end
  end

  defp extract_atomically(script, cache_root, cache, digest, opts) do
    staging = Path.join(cache_root, ".extract-#{random_suffix()}")
    extract = Keyword.get(opts, :extract, &:escript.extract/2)
    unzip = Keyword.get(opts, :unzip, &:zip.extract/2)

    try do
      with :ok <- File.mkdir(staging),
           :ok <- File.chmod(staging, 0o700),
           {:ok, sections} <- extract.(String.to_charlist(script), []),
           {:ok, archive} <- Keyword.fetch(sections, :archive),
           {:ok, _files} <- unzip.(archive, cwd: String.to_charlist(staging)),
           {:ok, relative_ebin_paths} <- extracted_ebin_paths(staging),
           :ok <- write_marker(staging, digest, relative_ebin_paths),
           :ok <- install_cache(staging, cache) do
        validate_cache(cache, digest)
      end
    after
      if File.exists?(staging), do: File.rm_rf!(staging)
    end
  end

  defp install_cache(staging, cache) do
    case File.rename(staging, cache) do
      :ok -> :ok
      {:error, reason} when reason in [:eexist, :enotempty] -> :ok
      {:error, reason} -> {:error, {:escript_cache_install_failed, reason}}
    end
  end

  defp extracted_ebin_paths(staging) do
    paths =
      staging
      |> Path.join("*/ebin")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, staging))
      |> Enum.sort()

    if paths == [], do: {:error, :escript_cache_has_no_code_paths}, else: {:ok, paths}
  end

  defp write_marker(staging, digest, paths) do
    marker = Path.join(staging, @marker)
    contents = Enum.join([digest | paths], "\n") <> "\n"

    with :ok <- File.write(marker, contents, [:binary, :exclusive]) do
      File.chmod(marker, 0o600)
    end
  end

  defp validate_cache(cache, digest) do
    case File.lstat(cache) do
      {:ok, %{type: :directory, mode: mode}} -> validate_cache_directory(cache, digest, mode)
      {:ok, _stat} -> {:error, :escript_cache_is_not_a_directory}
      {:error, :enoent} -> {:error, :escript_cache_missing}
      {:error, reason} -> {:error, {:escript_cache_invalid, reason}}
    end
  end

  defp validate_cache_directory(cache, digest, mode) do
    with true <- Bitwise.band(mode, 0o077) == 0,
         marker = Path.join(cache, @marker),
         {:ok, %{type: :regular, mode: marker_mode}} <- File.lstat(marker),
         true <- Bitwise.band(marker_mode, 0o077) == 0,
         {:ok, contents} <- File.read(marker),
         [^digest | paths] when paths != [] <- String.split(contents, "\n", trim: true),
         true <- Enum.all?(paths, &safe_cache_path?/1),
         ebin_paths = Enum.map(paths, &Path.join(cache, &1)),
         true <- Enum.all?(ebin_paths, &private_code_directory?/1) do
      {:ok, ebin_paths}
    else
      false -> {:error, :escript_cache_is_not_private_or_complete}
      {:ok, _stat} -> {:error, :escript_cache_is_not_a_directory}
      {:error, reason} -> {:error, {:escript_cache_invalid, reason}}
      _invalid -> {:error, :escript_cache_marker_invalid}
    end
  end

  defp safe_cache_path?(path) do
    Path.type(path) == :relative and path != "" and
      not Enum.member?(Path.split(path), "..") and Path.basename(path) == "ebin"
  end

  defp private_code_directory?(path) do
    match?({:ok, %{type: :directory}}, File.lstat(path))
  end

  defp ensure_private_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> File.chmod(path, 0o700)
      {:ok, _stat} -> {:error, {:unsafe_cache_path, path}}
      {:error, :enoent} -> create_private_directory(path)
      {:error, reason} -> {:error, {:cache_directory_unavailable, path, reason}}
    end
  end

  defp create_private_directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %{type: :directory}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      {:ok, _stat} -> {:error, {:unsafe_cache_path, path}}
      {:error, reason} -> {:error, {:cache_directory_unavailable, path, reason}}
    end
  end

  defp file_digest(path) do
    with {:ok, "sha256:" <> digest} <- Digest.file(path) do
      {:ok, digest}
    end
  end

  defp random_suffix do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
