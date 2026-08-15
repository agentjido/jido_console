defmodule Jido.Console.Release.Npm do
  @moduledoc """
  Prepares the npm entry package and exact macOS ARM64 target package.

  Installation does not compile Erlang or Elixir and does not download a
  release from an install script. Publication is out of scope.
  """

  alias Jido.Console.Release.Channel

  @entry "@agentjido/jido-console"
  @target "@agentjido/jido-console-darwin-arm64"

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

  @doc "Installs through the shared channel lifecycle for one npm flow."
  @spec install(Path.t(), Path.t(), atom(), keyword()) :: {:ok, Channel.install()} | {:error, term()}
  def install(payload_dir, prefix, flow, opts \\ []) when flow in [:global, :local, :exec, :npx] do
    with {:ok, packages} <- packages(payload_dir),
         :ok <- reject_install_scripts(packages) do
      Channel.install(:npm, payload_dir, prefix, opts)
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

  defp decode(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end
end
