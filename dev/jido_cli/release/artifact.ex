defmodule Jido.Cli.Release.Artifact do
  @moduledoc "Builds one deterministic macOS ARM64 package with a private OTP runtime."

  alias Jido.Cli.Release.{Contract, CrossRepo, LicenseAudit}

  @target "darwin-arm64"
  @runtime_apps ~w(time_zone_info extractous_ex req_llm llm_db)

  @doc "Builds and assembles one candidate in an isolated output directory."
  @spec build!(Path.t(), keyword()) :: map()
  def build!(candidate_dir, opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!()) |> Path.expand()
    validate_host!()

    if Keyword.get(opts, :build_release, true) do
      run!("mix", ["release", "jido", "--overwrite"], project_root, [{"MIX_ENV", "prod"}])
    end

    release_root = Path.join(project_root, "_build/prod/rel/jido")
    assemble!(release_root, candidate_dir, Keyword.put(opts, :project_root, project_root))
  end

  @doc "Assembles a previously built Mix release. This function does not publish it."
  @spec assemble!(Path.t(), Path.t(), keyword()) :: map()
  def assemble!(release_root, candidate_dir, opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!()) |> Path.expand()
    version = Jido.Cli.Release.Identity.version()
    source = Keyword.get_lazy(opts, :source, fn -> source_identity!(project_root) end)
    source_date_epoch = Keyword.get_lazy(opts, :source_date_epoch, fn -> source_epoch!(project_root) end)
    identity = Jido.Cli.Release.Identity.current()
    root_name = Contract.root_name(version, @target)
    package_root = Path.join(candidate_dir, root_name)

    File.mkdir_p!(Path.join(package_root, "bin"))
    copy_tree!(release_root, Path.join(package_root, "libexec"))
    copy_file!(Path.join(project_root, "rel/bin/jido"), Path.join(package_root, "bin/jido"))
    File.chmod!(Path.join(package_root, "bin/jido"), 0o755)
    copy_file!(Path.join(project_root, "LICENSE"), Path.join(package_root, "LICENSE"))
    copy_offline_suite!(project_root, package_root)

    components = LicenseAudit.audit!(release_root, project_root)
    File.write!(Path.join(package_root, "THIRD_PARTY_NOTICES"), LicenseAudit.notices(components))

    runtime_data = runtime_data!(package_root)
    native_files = native_files(package_root)
    files = file_inventory(package_root)

    metadata =
      Contract.metadata!(
        version: version,
        target: @target,
        identity: identity,
        source: source,
        jidoka_ref: CrossRepo.pinned_ref!(),
        source_date_epoch: source_date_epoch,
        files: files,
        runtime_data: runtime_data
      )
      |> Map.put("archive_checksum", "checksums.txt")
      |> Map.put("components", Enum.map(components, &public_component/1))
      |> Map.put("native_files", native_files)
      |> Map.update!("build", fn build ->
        build
        |> Map.put("build_time_utc", epoch_iso8601(source_date_epoch))
        |> Map.put("reproducible", true)
        |> Map.put("toolchain_file", ".tool-versions")
      end)

    :ok = Contract.validate_metadata(metadata)
    write_json!(Path.join(package_root, "release.json"), metadata)
    :ok = Contract.validate_layout(package_root, metadata)

    normalize_times!(package_root, source_date_epoch)
    File.mkdir_p!(candidate_dir)

    archive = Path.join(candidate_dir, metadata["artifact"])
    create_archive!(archive, candidate_dir, package_root)
    archive_sha256 = sha256_file(archive)

    outputs = %{
      archive: archive,
      archive_sha256: archive_sha256,
      metadata: metadata,
      package_root: package_root,
      components: components,
      source_date_epoch: source_date_epoch,
      target: @target,
      version: version
    }

    write_external_outputs!(candidate_dir, outputs)
    outputs
  end

  @doc "Returns stable SHA-256 and size records for package files except release.json."
  @spec file_inventory(Path.t()) :: [map()]
  def file_inventory(package_root) do
    package_root
    |> regular_files()
    |> Enum.reject(&(Path.basename(&1) == "release.json"))
    |> Enum.map(fn path ->
      %{
        "path" => Path.relative_to(path, package_root),
        "sha256" => sha256_file(path),
        "size" => File.stat!(path).size
      }
    end)
  end

  @doc "Returns the lower-case SHA-256 value for one file."
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp write_external_outputs!(candidate_dir, outputs) do
    metadata = outputs.metadata
    archive_name = Path.basename(outputs.archive)

    File.write!(
      Path.join(candidate_dir, "checksums.txt"),
      "#{outputs.archive_sha256}  #{archive_name}\n"
    )

    write_json!(Path.join(candidate_dir, "release.json"), metadata)
    write_json!(Path.join(candidate_dir, "sbom.json"), sbom(outputs))
    write_json!(Path.join(candidate_dir, "provenance.json"), provenance(outputs))
  end

  defp sbom(outputs) do
    %{
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.5",
      "version" => 1,
      "metadata" => %{
        "timestamp" => epoch_iso8601(outputs.source_date_epoch),
        "component" => %{
          "type" => "application",
          "name" => "jido",
          "version" => outputs.version,
          "bom-ref" => "pkg:generic/jido@#{outputs.version}?target=#{outputs.target}"
        }
      },
      "components" =>
        Enum.map(outputs.components, fn component ->
          %{
            "type" => component_type(component.kind),
            "name" => component.name,
            "version" => component.version,
            "bom-ref" => "pkg:generic/#{component.name}@#{component.version}",
            "licenses" => Enum.map(component.licenses, &%{"license" => %{"id" => &1}}),
            "externalReferences" => [%{"type" => "distribution", "url" => component.source}],
            "properties" => [
              %{"name" => "jido:component-kind", "value" => Atom.to_string(component.kind)},
              %{"name" => "jido:native-files", "value" => Enum.join(component.native_files, ",")}
            ]
          }
        end)
    }
  end

  defp provenance(outputs) do
    identity = Jido.Cli.Release.Identity.current()

    %{
      "schema" => "jido.provenance",
      "schema_version" => 1,
      "builder" => "mix jido.release",
      "build_type" => "local-macos-arm64-mix-release",
      "build_time_utc" => epoch_iso8601(outputs.source_date_epoch),
      "subject" => %{
        "name" => Path.basename(outputs.archive),
        "sha256" => outputs.archive_sha256
      },
      "source" => outputs.metadata["source"],
      "target" => outputs.target,
      "inputs" => %{
        "mix_lock_sha256" => sha256_file("mix.lock"),
        "toolchain_sha256" => sha256_file(".tool-versions"),
        "elixir" => identity.elixir,
        "otp" => identity.otp,
        "jidoka" => identity.jidoka,
        "jidoka_ref" => outputs.metadata["runtime"]["jidoka_ref"]
      },
      "trust" => outputs.metadata["trust"],
      "distribution" => outputs.metadata["distribution"]
    }
  end

  defp public_component(component) do
    %{
      "name" => component.name,
      "version" => component.version,
      "kind" => Atom.to_string(component.kind),
      "source" => component.source,
      "licenses" => component.licenses,
      "license_file" => component.license_file,
      "native_files" => component.native_files
    }
  end

  defp runtime_data!(package_root) do
    Enum.map(@runtime_apps, fn app ->
      matches = Path.wildcard(Path.join(package_root, "libexec/lib/#{app}-*/priv"))

      case matches do
        [path] ->
          if File.dir?(path),
            do: Path.relative_to(path, package_root),
            else: raise("required runtime data is not a directory: #{app}")

        _other ->
          raise "required runtime data is missing or ambiguous: #{app}"
      end
    end)
  end

  defp native_files(package_root) do
    package_root
    |> regular_files()
    |> Enum.filter(&(Path.extname(&1) in [".so", ".dylib", ".bundle"]))
    |> Enum.map(&Path.relative_to(&1, package_root))
    |> Enum.sort()
  end

  defp create_archive!(archive, stage_root, package_root) do
    files =
      package_root
      |> regular_files()
      |> Enum.map(&Path.relative_to(&1, stage_root))
      |> Enum.map(&String.to_charlist/1)

    File.rm(archive)

    File.cd!(stage_root, fn ->
      case :erl_tar.create(String.to_charlist(archive), files, [:compressed]) do
        :ok -> :ok
        {:error, reason} -> raise "cannot create release archive: #{inspect(reason)}"
      end
    end)
  end

  defp regular_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp normalize_times!(package_root, epoch) do
    Enum.each(regular_files(package_root), &File.touch!(&1, epoch))
  end

  defp source_identity!(project_root) do
    commit = run!("git", ["rev-parse", "HEAD"], project_root) |> String.trim()
    dirty = run!("git", ["status", "--porcelain", "--untracked-files=normal"], project_root) != ""
    %{commit: commit, dirty: dirty}
  end

  defp source_epoch!(project_root) do
    project_root
    |> then(&run!("git", ["show", "-s", "--format=%ct", "HEAD"], &1))
    |> String.trim()
    |> String.to_integer()
  end

  defp validate_host! do
    architecture = :erlang.system_info(:system_architecture) |> to_string()

    unless match?({:unix, :darwin}, :os.type()) and String.starts_with?(architecture, "aarch64-") do
      raise "darwin-arm64 release must build on native macOS ARM64; found #{architecture}"
    end
  end

  defp copy_offline_suite!(project_root, package_root) do
    source = Path.join(project_root, "release/fixtures/offline")
    target = Path.join(package_root, "share/jido/offline")
    copy_tree!(source, target)
  end

  defp copy_tree!(source, target) do
    File.rm_rf!(target)
    File.mkdir_p!(Path.dirname(target))

    case File.cp_r(source, target) do
      {:ok, _files} -> :ok
      {:error, reason, path} -> raise "cannot copy #{path}: #{inspect(reason)}"
    end
  end

  defp copy_file!(source, target) do
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
  end

  defp run!(command, args, directory, env \\ []) do
    case System.cmd(command, args, cd: directory, env: env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "#{command} failed with status #{status}:\n#{output}"
    end
  end

  defp write_json!(path, value) do
    File.write!(path, Jason.encode_to_iodata!(value, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n"))
  end

  defp epoch_iso8601(epoch), do: epoch |> DateTime.from_unix!() |> DateTime.to_iso8601()
  defp component_type(:otp), do: "framework"
  defp component_type(:elixir), do: "framework"
  defp component_type(_kind), do: "library"
end
