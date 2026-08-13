defmodule Jido.Cli.Bootstrap do
  @moduledoc "Secure runtime startup for the escript and packaged CLI."

  @marker ".complete"

  alias Jido.Cli.Digest

  @doc "Makes bundled private files available and starts the CLI applications."
  @spec start_applications(keyword()) :: :ok | {:error, term()}
  def start_applications(opts \\ []) do
    ensure_started = Keyword.get(opts, :ensure_all_started, &Application.ensure_all_started/1)

    with :ok <- make_priv_files_accessible(opts),
         {:ok, _applications} <- ensure_started.(:jido_cli) do
      :ok
    end
  end

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
    root =
      Keyword.get_lazy(opts, :cache_root, fn ->
        :filename.basedir(:user_cache, ~c"jido") |> List.to_string()
      end)

    with :ok <- ensure_private_directory(root),
         escript_root = Path.join(root, "escript"),
         :ok <- ensure_private_directory(escript_root) do
      {:ok, escript_root}
    end
  end

  defp cache_path(root, digest, opts) do
    version = Keyword.get(opts, :version, Jido.Cli.Release.Identity.version())
    otp = Keyword.get(opts, :otp_release, :erlang.system_info(:otp_release)) |> to_string()
    Path.join(root, "#{version}-otp-#{otp}-#{digest}")
  end

  defp ensure_extracted(script, cache_root, cache, digest, opts) do
    if File.exists?(cache) do
      validate_cache(cache, digest)
    else
      extract_atomically(script, cache_root, cache, digest, opts)
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
    with {:ok, %{type: :directory, mode: mode}} <- File.lstat(cache),
         true <- Bitwise.band(mode, 0o077) == 0,
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
