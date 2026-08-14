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
  @non_empty_string Zoi.string() |> Zoi.regex(~r/\S/)
  @version_string Zoi.string() |> Zoi.regex(~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/)
  @digest_string Zoi.string() |> Zoi.regex(~r/^[0-9a-f]{64}$/)
  @commit_string Zoi.string() |> Zoi.regex(~r/^[0-9a-f]{40}$/)
  @file_schema Zoi.map(
                 %{
                   "path" => @non_empty_string,
                   "sha256" => @digest_string,
                   "size" => Zoi.integer() |> Zoi.gte(0)
                 },
                 unrecognized_keys: :error
               )
  @component_schema Zoi.map(
                      %{
                        "kind" => Zoi.enum(["dependency", "elixir", "otp", "project"]),
                        "license_file" => @non_empty_string |> Zoi.nullish(),
                        "licenses" => Zoi.array(@non_empty_string),
                        "name" => @non_empty_string,
                        "native_files" => Zoi.array(@non_empty_string),
                        "source" => @non_empty_string,
                        "version" => @non_empty_string
                      },
                      unrecognized_keys: :error
                    )
  @metadata_schema Zoi.map(
                     %{
                       "archive_checksum" => Zoi.enum(["checksums.txt"]) |> Zoi.optional(),
                       "artifact" => @non_empty_string,
                       "build" =>
                         Zoi.map(
                           %{
                             "build_time_utc" => @non_empty_string |> Zoi.optional(),
                             "launcher_version" => Zoi.enum([1]),
                             "package_method" => Zoi.enum(["mix_release"]),
                             "reproducible" => Zoi.boolean() |> Zoi.optional(),
                             "source_date_epoch" => Zoi.integer() |> Zoi.gte(0),
                             "toolchain_file" => Zoi.enum([".tool-versions"]) |> Zoi.optional()
                           },
                           unrecognized_keys: :error
                         ),
                       "components" => Zoi.array(@component_schema) |> Zoi.optional(),
                       "digest_scope" => Zoi.enum(["all package files except release.json"]),
                       "distribution" =>
                         Zoi.map(
                           %{"github" => Zoi.boolean(), "homebrew" => Zoi.boolean()},
                           unrecognized_keys: :error
                         ),
                       "executable" => Zoi.enum([@executable]),
                       "files" => Zoi.array(@file_schema),
                       "native_files" => Zoi.array(@non_empty_string) |> Zoi.optional(),
                       "package" => Zoi.enum(["jido_cli"]),
                       "product" => Zoi.enum(["jido"]),
                       "root" => @non_empty_string,
                       "runtime" =>
                         Zoi.map(
                           %{
                             "elixir" => @non_empty_string,
                             "jidoka" => @non_empty_string,
                             "jidoka_ref" => @commit_string,
                             "otp" => @non_empty_string
                           },
                           unrecognized_keys: :error
                         ),
                       "runtime_data" => Zoi.array(@non_empty_string),
                       "schema" => Zoi.enum([@schema]),
                       "schema_version" => Zoi.enum([@schema_version]),
                       "source" =>
                         Zoi.map(
                           %{
                             "commit" => Zoi.string() |> Zoi.min(7),
                             "dirty" => Zoi.boolean()
                           },
                           unrecognized_keys: :error
                         ),
                       "target" => Zoi.enum(Map.keys(@targets)),
                       "trust" =>
                         Zoi.map(
                           %{
                             "notarized" => Zoi.boolean(),
                             "publishable" => Zoi.boolean(),
                             "signed" => Zoi.boolean()
                           },
                           unrecognized_keys: :error
                         ),
                       "version" => @version_string
                     },
                     unrecognized_keys: :error
                   )

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
        "jidoka" => Map.fetch!(identity, :jidoka),
        "jidoka_ref" => Keyword.fetch!(attrs, :jidoka_ref)
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
    with {:ok, metadata} <- Jido.Cli.Document.validate(@metadata_schema, metadata, :release_metadata),
         version = metadata["version"],
         target = metadata["target"],
         :ok <- equal(metadata, "root", root_name(version, target)),
         :ok <- equal(metadata, "artifact", archive_name(version, target)),
         do: validate_file_list(metadata["files"])
  end

  def validate_metadata(other), do: {:error, {:metadata_not_a_map, other}}

  @doc "Validates the package layout and launcher contract."
  @spec validate_layout(Path.t(), map()) :: :ok | {:error, term()}
  def validate_layout(root, metadata) do
    with :ok <- validate_metadata(metadata),
         :ok <- validate_root_name(root, metadata),
         :ok <- validate_required_paths(root),
         :ok <- validate_executable(root) do
      validate_launcher(root)
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

  defp safe_relative_path?(path) do
    Path.type(path) == :relative and
      path != "" and
      not Enum.member?(Path.split(path), "..")
  end
end
