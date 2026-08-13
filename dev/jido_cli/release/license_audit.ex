defmodule Jido.Cli.Release.LicenseAudit do
  @moduledoc "Audits and documents all applications shipped in a local release."

  @otp_apps ~w(asn1 compiler crypto inets kernel mnesia public_key sasl ssl stdlib)
  @elixir_apps ~w(eex elixir iex logger)

  @doc "Returns reviewed component records for one assembled Mix release."
  @spec audit!(Path.t(), Path.t()) :: [map()]
  def audit!(release_root, project_root) do
    policy = policy!(project_root)
    app_dirs = release_root |> Path.join("lib/*") |> Path.wildcard() |> Enum.filter(&File.dir?/1)
    shipped = app_dirs |> Enum.map(&Path.basename/1) |> Enum.sort()
    reviewed = Enum.sort(policy.reviewed_components)

    if shipped != reviewed do
      raise "license policy does not match shipped components: " <>
              "added=#{inspect(shipped -- reviewed)} removed=#{inspect(reviewed -- shipped)}"
    end

    components = Enum.map(app_dirs, &component!(&1, project_root, policy))

    case Enum.frequencies_by(components, & &1.name) |> Enum.filter(fn {_name, count} -> count != 1 end) do
      [] -> Enum.sort_by(components, & &1.name)
      duplicates -> raise "duplicate shipped license records: #{inspect(duplicates)}"
    end
  end

  @doc "Creates a deterministic notice file from reviewed component records."
  @spec notices([map()]) :: String.t()
  def notices(components) do
    header = """
    Jido third-party notices

    This file identifies components in the packaged private runtime. It is an
    inventory and notice record. It is not legal advice.

    Erlang/OTP and Elixir are licensed under the Apache License 2.0. Their
    source projects keep the authoritative copyright and notice files.
    Erlang/OTP: https://github.com/erlang/otp
    Elixir: https://github.com/elixir-lang/elixir
    """

    records =
      Enum.map_join(components, "\n", fn component ->
        native =
          case component.native_files do
            [] -> "none"
            files -> Enum.join(files, ", ")
          end

        license_text =
          case component.license_path do
            nil ->
              "License text: use the authoritative source above."

            path ->
              if Path.basename(path) == "hex_metadata.config" do
                "License declaration: #{component.license_file}"
              else
                "License file: #{component.license_file}\n\n" <> File.read!(path)
              end
          end

        """
        ------------------------------------------------------------------------
        #{component.name} #{component.version}
        Source: #{component.source}
        Licenses: #{Enum.join(component.licenses, ", ")}
        Native files: #{native}
        #{license_text}
        """
      end)

    header <> "\n" <> records
  end

  defp component!(app_dir, project_root, policy) do
    {name, version} = app_identity!(app_dir)
    {kind, source, licenses, source_root} = source_identity!(name, version, project_root)

    unknown = licenses -- policy.allowed_licenses

    if unknown != [] do
      raise "unreviewed or forbidden license for #{name}: #{inspect(unknown)}"
    end

    {license_path, license_file} = license_file(source_root, project_root, kind)

    if kind == :dependency and is_nil(license_path) do
      raise "missing license file for shipped dependency #{name}"
    end

    %{
      name: name,
      version: version,
      kind: kind,
      source: source,
      licenses: licenses,
      license_file: license_file,
      license_path: license_path,
      native_files: native_files(app_dir)
    }
  end

  defp app_identity!(app_dir) do
    app_file = app_dir |> Path.join("ebin/*.app") |> Path.wildcard() |> List.first()

    case app_file && :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, name, properties}]} ->
        {Atom.to_string(name), properties |> Keyword.fetch!(:vsn) |> to_string()}

      other ->
        raise "cannot read shipped application identity from #{app_dir}: #{inspect(other)}"
    end
  end

  defp source_identity!("jido_cli", version, project_root) do
    {:project, "https://github.com/mikehostetler/jido_cli@#{version}", ["Apache-2.0"], project_root}
  end

  defp source_identity!(name, _version, _project_root) when name in @otp_apps do
    {:otp, "https://github.com/erlang/otp@OTP-#{System.otp_release()}", ["Apache-2.0"], nil}
  end

  defp source_identity!(name, version, _project_root) when name in @elixir_apps do
    {:elixir, "https://github.com/elixir-lang/elixir@v#{version}", ["Apache-2.0"], elixir_root()}
  end

  defp source_identity!(name, version, project_root) do
    dep_root = Path.join([project_root, "deps", name])
    lock = Mix.Dep.Lock.read() |> Map.fetch!(String.to_existing_atom(name))
    licenses = dependency_licenses!(dep_root, name)

    source =
      case lock do
        {:hex, package, ^version, checksum, _managers, _deps, repo, outer_checksum} ->
          "hex://#{repo}/#{package}@#{version}?checksum=#{encode_checksum(checksum)}&outer=#{outer_checksum}"

        {:git, url, revision, _opts} ->
          "#{url}@#{revision}"

        other ->
          raise "unsupported lock identity for shipped dependency #{name}: #{inspect(other)}"
      end

    {:dependency, source, licenses, dep_root}
  end

  defp dependency_licenses!(dep_root, name) do
    metadata = Path.join(dep_root, "hex_metadata.config")

    case :file.consult(String.to_charlist(metadata)) do
      {:ok, terms} ->
        case List.keyfind(terms, "licenses", 0) do
          {"licenses", licenses} -> Enum.map(licenses, &to_string/1)
          nil -> raise "missing license metadata for #{name}"
        end

      _other when name == "jidoka" ->
        ["Apache-2.0"]

      other ->
        raise "cannot read license metadata for #{name}: #{inspect(other)}"
    end
  end

  defp license_file(nil, _project_root, _kind), do: {nil, nil}

  defp license_file(source_root, project_root, kind) do
    path =
      ["LICENSE*", "COPYING*", "COPYRIGHT*", "NOTICE*", "LICENSES/*"]
      |> Enum.flat_map(&Path.wildcard(Path.join(source_root, &1)))
      |> Enum.sort()
      |> Enum.find(&File.regular?/1)

    path =
      if is_nil(path) and File.regular?(Path.join(source_root, "hex_metadata.config")),
        do: Path.join(source_root, "hex_metadata.config"),
        else: path

    relative =
      cond do
        is_nil(path) -> nil
        kind == :elixir -> "Elixir/LICENSE"
        true -> Path.relative_to(path, project_root)
      end

    {path, relative}
  end

  defp native_files(app_dir) do
    app_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and Path.extname(&1) in [".so", ".dylib", ".bundle"]))
    |> Enum.map(&Path.relative_to(&1, app_dir))
    |> Enum.sort()
  end

  defp policy!(project_root) do
    path = Path.join(project_root, "release/license_policy.exs")
    {policy, _bindings} = Code.eval_file(path)

    unless policy.schema == "jido.license-policy" and policy.schema_version == 1 do
      raise "invalid release license policy"
    end

    policy
  end

  defp encode_checksum(checksum) when is_binary(checksum), do: Base.encode16(checksum, case: :lower)
  defp encode_checksum(checksum), do: to_string(checksum)

  defp elixir_root do
    :elixir
    |> :code.lib_dir()
    |> List.to_string()
    |> Path.join("../..")
    |> Path.expand()
  end
end
