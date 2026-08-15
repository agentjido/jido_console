defmodule Jido.Console.Release.Channel do
  @moduledoc """
  Prepares and exercises v0.1 distribution channels from one signed payload.

  Channels never compile Erlang or Elixir and never download a replacement
  runtime. Production publication is out of scope.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Payload

  @channels [:archive, :homebrew, :npm]
  @stages [:install, :first_run, :update, :remove]

  @type channel :: :archive | :homebrew | :npm
  @type install :: %{
          channel: channel(),
          root: String.t(),
          version: String.t(),
          license: String.t(),
          payload_sha256: String.t()
        }

  @doc "Returns the v0.1 channel identifiers."
  @spec channels() :: [channel()]
  def channels, do: @channels

  @doc "Returns the lifecycle stages each channel must prove."
  @spec stages() :: [atom()]
  def stages, do: @stages

  @doc "Verifies the signed payload and installs it into an isolated prefix."
  @spec install(channel(), Path.t(), Path.t(), keyword()) :: {:ok, install()} | {:error, term()}
  def install(channel, payload_dir, prefix, opts \\ []) when channel in @channels do
    public_key = Keyword.get(opts, :public_key)

    with :ok <- require_public_key(public_key),
         :ok <- verify_or_error(payload_dir, public_key),
         {:ok, record} <- read_payload(payload_dir),
         {:ok, sha} <- Payload.checksum(payload_dir, record["archive"]),
         :ok <- copy_payload(payload_dir, prefix, record) do
      {:ok,
       %{
         channel: channel,
         root: prefix,
         version: record["version"],
         license: record["license"],
         payload_sha256: sha
       }}
    end
  end

  @doc "Runs the installed payload executable once without a host toolchain."
  @spec first_run(install()) :: {:ok, map()} | {:error, term()}
  def first_run(install) do
    version_path = Path.join(install.root, "release.json")

    with {:ok, body} <- File.read(version_path),
         {:ok, release} <- Jason.decode(body),
         true <- release["version"] == install.version,
         {:ok, executable} <- installed_executable(install.root),
         {:ok, output} <- exec_version(executable),
         true <- version_printed?(output, install.version) do
      {:ok,
       %{
         "stage" => "first_run",
         "version" => install.version,
         "license" => install.license,
         "toolchain" => "bundled",
         "compiled" => false,
         "executable" => "bin/jido"
       }}
    else
      false -> {:error, :version_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Replaces an install only after the new payload verifies."
  @spec update(install(), Path.t(), keyword()) :: {:ok, install()} | {:error, term()}
  def update(install, new_payload_dir, opts \\ []) do
    install(install.channel, new_payload_dir, install.root, opts)
  end

  @doc "Removes owned files and leaves user data in place."
  @spec remove(install(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove(install, opts \\ []) do
    keep = Keyword.get(opts, :user_data, [])

    install.root
    |> File.ls!()
    |> Enum.reject(&(&1 in keep))
    |> Enum.each(fn name -> File.rm_rf!(Path.join(install.root, name)) end)

    {:ok, %{"stage" => "remove", "user_data" => keep, "root_exists" => File.dir?(install.root)}}
  end

  @doc "Formats redacted lifecycle evidence."
  @spec evidence(channel(), [map()]) :: map()
  def evidence(channel, stages) do
    %{
      "schema" => "jido.channel-lifecycle",
      "schema_version" => 1,
      "channel" => Atom.to_string(channel),
      "published" => false,
      "stages" => stages,
      "summary" => Redaction.redact(inspect(stages))
    }
  end

  defp require_public_key(key) when is_binary(key) and byte_size(key) > 0, do: :ok
  defp require_public_key(_key), do: {:error, :trusted_public_key_required}

  defp verify_or_error(payload_dir, public_key) do
    case Payload.verify(payload_dir, public_key: public_key) do
      {:ok, _report} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_payload(payload_dir, prefix, record) do
    File.mkdir_p!(prefix)

    Enum.each(
      ["release.json", "sbom.json", "provenance.json", "checksums.txt", "LICENSE", record["archive"]],
      fn name ->
        source = Path.join(payload_dir, name)
        if File.regular?(source), do: File.cp!(source, Path.join(prefix, name))
      end
    )

    extract_archive(prefix, record["archive"])
  end

  defp extract_archive(prefix, archive_name) when is_binary(archive_name) do
    archive = Path.join(prefix, archive_name)

    with {:ok, members} <- :erl_tar.table(String.to_charlist(archive), [:compressed]),
         :ok <- safe_tar_members(members),
         :ok <- :erl_tar.extract(String.to_charlist(archive), [:compressed, cwd: String.to_charlist(prefix)]) do
      :ok
    else
      {:error, reason} -> {:error, {:archive_extract_failed, reason}}
    end
  end

  defp extract_archive(_prefix, _archive_name), do: {:error, :archive_missing}

  defp safe_tar_members(members) do
    if Enum.any?(members, &unsafe_tar_member?/1),
      do: {:error, :archive_path_unsafe},
      else: :ok
  end

  defp unsafe_tar_member?(member) do
    path = member |> tar_member_name() |> to_string()
    Path.type(path) == :absolute or Enum.any?(Path.split(path), &(&1 == ".."))
  end

  defp tar_member_name({name, _type, _size, _mtime, _mode, _uid, _gid}), do: name
  defp tar_member_name({name, _type, _size, _mtime, _mode, _uid, _gid, _type_name, _link}), do: name
  defp tar_member_name(name), do: name

  defp installed_executable(root) do
    root
    |> Path.join("**/bin/jido")
    |> Path.wildcard()
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> {:error, :installed_executable_missing}
      path -> {:ok, path}
    end
  end

  defp exec_version(executable) do
    case System.cmd(executable, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:first_run_failed, status, output}}
    end
  end

  defp version_printed?(output, version) when is_binary(output) and is_binary(version) do
    String.contains?(output, version)
  end

  defp read_payload(directory) do
    directory |> Path.join("payload.json") |> File.read() |> decode()
  end

  defp decode({:ok, body}), do: Jason.decode(body)
  defp decode({:error, reason}), do: {:error, reason}
end
