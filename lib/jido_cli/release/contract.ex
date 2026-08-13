defmodule Jido.Cli.Release.Contract do
  @moduledoc "Defines and validates the isolated Jido artifact contract."

  @schema "jido.release"
  @schema_version 1
  @executable "bin/jido"
  @required_paths [
    @executable,
    "libexec",
    "LICENSE",
    "THIRD_PARTY_NOTICES",
    "release.json"
  ]
  @targets %{
    "darwin-arm64" => %{archive_extension: ".tar.gz", os: "darwin", arch: "arm64"},
    "darwin-x64" => %{archive_extension: ".tar.gz", os: "darwin", arch: "x86_64"},
    "linux-x64" => %{archive_extension: ".tar.gz", os: "linux", arch: "x86_64"},
    "linux-arm64" => %{archive_extension: ".tar.gz", os: "linux", arch: "arm64"},
    "windows-x64" => %{archive_extension: ".zip", os: "windows", arch: "x86_64"}
  }

  @type target :: String.t()

  @doc "Returns the release metadata schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the supported target specification."
  @spec target_spec(target()) :: {:ok, map()} | {:error, {:unsupported_target, target()}}
  def target_spec(target) do
    case Map.fetch(@targets, target) do
      {:ok, spec} -> {:ok, Map.merge(spec, %{id: target, executable: @executable})}
      :error -> {:error, {:unsupported_target, target}}
    end
  end

  @doc "Returns the versioned package root directory name."
  @spec root_name(String.t(), target()) :: String.t()
  def root_name(version, target) do
    validate_version!(version)
    target_spec!(target)
    "jido-#{version}-#{target}"
  end

  @doc "Returns the immutable target archive name."
  @spec archive_name(String.t(), target()) :: String.t()
  def archive_name(version, target) do
    spec = target_spec!(target)
    root_name(version, target) <> spec.archive_extension
  end

  @doc "Builds and validates release metadata."
  @spec metadata!(keyword()) :: map()
  def metadata!(attrs) do
    version = Keyword.fetch!(attrs, :version)
    target = Keyword.fetch!(attrs, :target)
    identity = Keyword.fetch!(attrs, :identity)
    source = Keyword.fetch!(attrs, :source)

    metadata = %{
      "schema" => @schema,
      "schema_version" => @schema_version,
      "product" => "jido",
      "package" => "jido_cli",
      "version" => version,
      "target" => target,
      "artifact" => archive_name(version, target),
      "root" => root_name(version, target),
      "executable" => @executable,
      "runtime" => %{
        "elixir" => Map.fetch!(identity, :elixir),
        "otp" => Map.fetch!(identity, :otp),
        "jidoka" => Map.fetch!(identity, :jidoka)
      },
      "source" => %{
        "commit" => Map.fetch!(source, :commit),
        "dirty" => Map.fetch!(source, :dirty)
      },
      "build" => %{
        "package_method" => "mix_release",
        "launcher_version" => 1,
        "source_date_epoch" => Keyword.fetch!(attrs, :source_date_epoch)
      },
      "files" => Keyword.get(attrs, :files, []),
      "runtime_data" => Keyword.get(attrs, :runtime_data, []),
      "digest_scope" => "all package files except release.json",
      "trust" => %{
        "signed" => false,
        "notarized" => false,
        "publishable" => not Map.fetch!(source, :dirty)
      },
      "distribution" => %{
        "github" => false,
        "homebrew" => false
      }
    }

    case validate_metadata(metadata) do
      :ok -> metadata
      {:error, reason} -> raise ArgumentError, "invalid release metadata: #{inspect(reason)}"
    end
  end

  @doc "Validates release metadata without changing it."
  @spec validate_metadata(term()) :: :ok | {:error, term()}
  def validate_metadata(%{} = metadata) do
    with :ok <- equal(metadata, "schema", @schema),
         :ok <- equal(metadata, "schema_version", @schema_version),
         :ok <- equal(metadata, "product", "jido"),
         :ok <- equal(metadata, "package", "jido_cli"),
         {:ok, version} <- fetch_string(metadata, "version"),
         :ok <- validate_version(version),
         {:ok, target} <- fetch_string(metadata, "target"),
         {:ok, _target_spec} <- target_spec(target),
         :ok <- equal(metadata, "root", root_name(version, target)),
         :ok <- equal(metadata, "artifact", archive_name(version, target)),
         :ok <- equal(metadata, "executable", @executable),
         :ok <- validate_runtime(metadata["runtime"]),
         :ok <- validate_source(metadata["source"]),
         :ok <- validate_build(metadata["build"]),
         :ok <- validate_file_list(metadata["files"]),
         :ok <- validate_string_list(metadata["runtime_data"]),
         :ok <- validate_trust(metadata["trust"]),
         :ok <- validate_distribution(metadata["distribution"]) do
      :ok
    end
  end

  def validate_metadata(other), do: {:error, {:metadata_not_a_map, other}}

  @doc "Validates the package layout and launcher contract."
  @spec validate_layout(Path.t(), map()) :: :ok | {:error, term()}
  def validate_layout(root, metadata) do
    with :ok <- validate_metadata(metadata),
         :ok <- validate_root_name(root, metadata),
         :ok <- validate_required_paths(root),
         :ok <- validate_executable(root),
         :ok <- validate_launcher(root) do
      :ok
    end
  end

  @doc "Returns the inputs needed by a future Homebrew formula."
  @spec homebrew_inputs(map(), String.t()) :: map()
  def homebrew_inputs(metadata, sha256) do
    :ok = validate_metadata(metadata)

    unless Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256) do
      raise ArgumentError, "invalid SHA-256 value"
    end

    %{
      "version" => metadata["version"],
      "target" => metadata["target"],
      "artifact" => metadata["artifact"],
      "sha256" => sha256,
      "executable" => metadata["executable"]
    }
  end

  defp target_spec!(target) do
    case target_spec(target) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp validate_version!(version) do
    case validate_version(version) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp validate_version(version) when is_binary(version) do
    if Regex.match?(~r/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/, version),
      do: :ok,
      else: {:error, {:invalid_version, version}}
  end

  defp validate_version(version), do: {:error, {:invalid_version, version}}

  defp validate_runtime(%{} = runtime) do
    with {:ok, _elixir} <- fetch_string(runtime, "elixir"),
         {:ok, _otp} <- fetch_string(runtime, "otp"),
         {:ok, _jidoka} <- fetch_string(runtime, "jidoka") do
      :ok
    end
  end

  defp validate_runtime(value), do: {:error, {:invalid_runtime, value}}

  defp validate_source(%{"commit" => commit, "dirty" => dirty})
       when is_binary(commit) and byte_size(commit) >= 7 and is_boolean(dirty),
       do: :ok

  defp validate_source(value), do: {:error, {:invalid_source, value}}

  defp validate_build(%{
         "package_method" => "mix_release",
         "launcher_version" => 1,
         "source_date_epoch" => epoch
       })
       when is_integer(epoch) and epoch >= 0,
       do: :ok

  defp validate_build(value), do: {:error, {:invalid_build, value}}

  defp validate_file_list(files) when is_list(files) do
    if Enum.all?(files, fn
         %{"path" => path, "sha256" => digest, "size" => size}
         when is_binary(path) and is_binary(digest) and is_integer(size) and size >= 0 ->
           safe_relative_path?(path) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

         _other ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_file_inventory}
  end

  defp validate_file_list(value), do: {:error, {:invalid_file_inventory, value}}

  defp validate_string_list(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_runtime_data}
  end

  defp validate_string_list(value), do: {:error, {:invalid_runtime_data, value}}

  defp validate_trust(%{
         "signed" => signed,
         "notarized" => notarized,
         "publishable" => publishable
       })
       when is_boolean(signed) and is_boolean(notarized) and is_boolean(publishable),
       do: :ok

  defp validate_trust(value), do: {:error, {:invalid_trust, value}}

  defp validate_distribution(%{"github" => github, "homebrew" => homebrew})
       when is_boolean(github) and is_boolean(homebrew),
       do: :ok

  defp validate_distribution(value), do: {:error, {:invalid_distribution, value}}

  defp validate_root_name(root, metadata) do
    if Path.basename(root) == metadata["root"],
      do: :ok,
      else: {:error, {:invalid_root_name, Path.basename(root), metadata["root"]}}
  end

  defp validate_required_paths(root) do
    case Enum.find(@required_paths, fn relative -> not File.exists?(Path.join(root, relative)) end) do
      nil -> :ok
      missing -> {:error, {:missing_package_path, missing}}
    end
  end

  defp validate_executable(root) do
    path = Path.join(root, @executable)

    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> :ok
      {:ok, stat} -> {:error, {:invalid_executable, stat}}
      {:error, reason} -> {:error, {:invalid_executable, reason}}
    end
  end

  defp validate_launcher(root) do
    launcher = File.read!(Path.join(root, @executable))

    cond do
      not String.starts_with?(launcher, "#!/bin/sh") ->
        {:error, :launcher_has_no_portable_shell_header}

      String.contains?(launcher, " eval ") ->
        {:error, :launcher_uses_release_eval}

      not String.contains?(launcher, "libexec") ->
        {:error, :launcher_does_not_use_private_runtime}

      not String.contains?(launcher, "-extra") ->
        {:error, :launcher_does_not_preserve_arguments}

      not String.contains?(launcher, "unset BINDIR ROOTDIR") ->
        {:error, :launcher_does_not_isolate_parent_beam}

      true ->
        :ok
    end
  end

  defp equal(map, key, expected) do
    case Map.fetch(map, key) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:invalid_field, key, actual, expected}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_string, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp safe_relative_path?(path) do
    Path.type(path) == :relative and
      path != "" and
      not Enum.member?(Path.split(path), "..")
  end
end
