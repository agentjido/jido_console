defmodule Jido.Console.Release.Npm do
  @moduledoc """
  Prepares the npm entry package and exact macOS ARM64 target package.

  Installation does not compile Erlang or Elixir and does not download a
  release from an install script. Publication is out of scope.
  """

  alias Jido.Console.Release.Channel

  @entry "@agentjido/jido-console"
  @target "@agentjido/jido-console-darwin-arm64"

  @type install :: %{
          channel: :npm,
          root: String.t(),
          executable: String.t(),
          payload_identity: Channel.payload_identity(),
          entry_root: String.t(),
          payload_root: String.t(),
          flow: :global | :local | :exec | :npx,
          entry_package: String.t(),
          target_package: String.t()
        }

  @doc "Returns the supported npm entry package name."
  @spec entry_name() :: String.t()
  def entry_name, do: @entry

  @doc "Returns the exact macOS ARM64 target package name."
  @spec target_name() :: String.t()
  def target_name, do: @target

  @doc "Builds the entry and target package manifests for one payload."
  @spec packages(Path.t()) :: {:ok, map()} | {:error, term()}
  def packages(payload_dir) do
    with {:ok, release} <- decode(Path.join(payload_dir, "release.json")),
         {:ok, sha} <- Jido.Console.Release.Payload.archive_checksum(payload_dir) do
      version = release["version"]

      {:ok,
       %{
         "entry" => %{
           "name" => @entry,
           "version" => version,
           "os" => ["darwin"],
           "cpu" => ["arm64"],
           "optionalDependencies" => %{@target => version},
           "scripts" => %{}
         },
         "target" => %{
           "name" => @target,
           "version" => version,
           "os" => ["darwin"],
           "cpu" => ["arm64"],
           "osx-checksum" => sha,
           "scripts" => %{}
         }
       }}
    end
  end

  @doc "Resolves the target package for a supported platform."
  @spec resolve(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%{"entry" => entry}, os, cpu) do
    if os in entry["os"] and cpu in entry["cpu"] do
      {:ok, @target}
    else
      {:error, {:unsupported_npm_target, os, cpu}}
    end
  end

  @doc "Executes and reports one npm lifecycle."
  @spec lifecycle(Path.t(), Path.t(), keyword()) :: Channel.result()
  def lifecycle(payload_dir, prefix, opts \\ []) do
    flow = Keyword.get(opts, :npm_flow, :global)

    Channel.execute(
      :npm,
      Channel.identity(payload_dir),
      fn ->
        case install(payload_dir, prefix, flow, opts) do
          {:ok, install} ->
            evidence =
              Channel.install_evidence(install, "npm_package", %{
                "flow" => Atom.to_string(flow),
                "entry_package" => @entry,
                "target_package" => @target,
                "entry_path" => Path.relative_to(install.entry_root, prefix),
                "target_path" => Path.relative_to(install.payload_root, prefix),
                "executable" => Path.relative_to(install.executable, prefix)
              })

            {:ok, install, evidence}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      fn install ->
        case Channel.first_run(install) do
          {:ok, evidence} -> {:ok, Map.put(evidence, "flow", Atom.to_string(flow))}
          {:error, reason} -> {:error, reason}
        end
      end,
      fn install ->
        case install(payload_dir, prefix, flow, opts) do
          {:ok, updated} ->
            evidence =
              Channel.identity_evidence("update", updated.payload_identity, %{
                "method" => "npm_package",
                "flow" => Atom.to_string(install.flow),
                "target_package" => @target
              })

            {:ok, updated, evidence}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &remove/1
    )
  end

  @doc "Installs the entry and target packages for one npm flow."
  @spec install(Path.t(), Path.t(), atom(), keyword()) :: {:ok, install()} | {:error, term()}
  def install(payload_dir, prefix, flow, opts \\ []) when flow in [:global, :local, :exec, :npx] do
    with {:ok, packages} <- packages(payload_dir),
         :ok <- reject_install_scripts(packages),
         {:ok, paths} <- write_packages(prefix, packages),
         {:ok, install} <- Channel.install_payload(:npm, payload_dir, paths.target, opts),
         :ok <- install_entry_executable(install.executable, paths.entry_executable, paths.executable) do
      {:ok,
       %{
         channel: :npm,
         root: prefix,
         executable: paths.executable,
         payload_identity: install.payload_identity,
         entry_root: paths.entry,
         payload_root: paths.target,
         flow: flow,
         entry_package: @entry,
         target_package: @target
       }}
    end
  end

  @doc "Removes the entry package, target package, and executable link."
  @spec remove(install()) :: {:ok, map()} | {:error, term()}
  def remove(install) do
    case File.rm_rf(install.root) do
      {:ok, _files} ->
        {:ok,
         %{
           "stage" => "remove",
           "status" => "pass",
           "method" => "npm_uninstall",
           "flow" => Atom.to_string(install.flow),
           "entry_package" => install.entry_package,
           "target_package" => install.target_package,
           "root_exists" => File.exists?(install.root)
         }}

      {:error, reason, path} ->
        {:error, {:npm_remove_failed, path, reason}}
    end
  end

  defp reject_install_scripts(%{"entry" => entry, "target" => target}) do
    scripts = Map.merge(entry["scripts"] || %{}, target["scripts"] || %{})

    if Map.has_key?(scripts, "preinstall") or Map.has_key?(scripts, "install") or
         Map.has_key?(scripts, "postinstall") do
      {:error, :npm_install_script_forbidden}
    else
      :ok
    end
  end

  defp write_packages(prefix, packages) do
    entry = Path.join(prefix, "node_modules/@agentjido/jido-console")
    target = Path.join(prefix, "node_modules/@agentjido/jido-console-darwin-arm64")
    entry_executable = Path.join(entry, "bin/jido")
    executable = Path.join(prefix, "bin/jido")

    with :ok <- File.mkdir_p(entry),
         :ok <- File.mkdir_p(target),
         :ok <- File.mkdir_p(Path.dirname(entry_executable)),
         :ok <- File.mkdir_p(Path.dirname(executable)),
         :ok <- write_json(Path.join(entry, "package.json"), entry_manifest(packages["entry"])),
         :ok <- write_json(Path.join(target, "package.json"), packages["target"]) do
      {:ok, %{entry: entry, target: target, entry_executable: entry_executable, executable: executable}}
    end
  end

  defp entry_manifest(manifest) do
    Map.put(manifest, "bin", %{"jido" => "bin/jido"})
  end

  defp install_entry_executable(source, entry_executable, command) do
    with {:ok, target} <- target_launcher(source),
         :ok <- File.write(entry_executable, entry_launcher(target)),
         :ok <- File.chmod(entry_executable, 0o755),
         :ok <- remove_command(command) do
      File.ln_s(Path.relative_to(entry_executable, Path.dirname(command)), command)
    end
  end

  defp target_launcher(source) do
    target_package = package_basename(@target)

    case Enum.split_while(Path.split(source), &(&1 != target_package)) do
      {_prefix, [^target_package | relative]} when relative != [] ->
        {:ok, Path.join(["..", "..", target_package | relative])}

      _other ->
        {:error, :npm_target_launcher_missing}
    end
  end

  defp package_basename(package), do: package |> String.split("/") |> List.last()

  defp entry_launcher(target) do
    """
    #!/bin/sh
    set -eu

    readlink_f() {
      cd "$(dirname "$1")" >/dev/null
      filename="$(basename "$1")"

      if [ -h "$filename" ]; then
        readlink_f "$(readlink "$filename")"
      else
        printf '%s/%s\n' "$(pwd -P)" "$filename"
      fi
    }

    SELF="$(readlink_f "$0")"
    ENTRY_BIN="$(CDPATH='' cd "$(dirname "$SELF")" && pwd -P)"

    exec "$ENTRY_BIN/#{target}" "$@"
    """
  end

  defp remove_command(command) do
    case File.rm(command) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_json(path, value) do
    File.write(path, Jason.encode!(value, pretty: true) <> "\n")
  end

  defp decode(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end
end
