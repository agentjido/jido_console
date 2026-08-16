defmodule Jido.Console.Release.Channel do
  @moduledoc """
  Defines the common release-channel result and owns the archive channel.

  A channel owner executes all lifecycle stages. This module supplies the
  shared payload operations and result validation, but it does not select or
  run the Homebrew or npm channels.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Payload

  @channels [:archive, :homebrew, :npm]
  @stages [:install, :first_run, :update, :remove]
  @stage_names Enum.map(@stages, &Atom.to_string/1)

  @type channel :: :archive | :homebrew | :npm
  @type payload_identity :: %{required(String.t()) => String.t() | map()}
  @type install :: %{
          channel: channel(),
          root: String.t(),
          executable: String.t(),
          payload_identity: payload_identity()
        }
  @type result :: map()

  @doc "Returns the required channel identifiers."
  @spec channels() :: [channel()]
  def channels, do: @channels

  @doc "Returns the lifecycle stages each channel must prove."
  @spec stages() :: [atom()]
  def stages, do: @stages

  @doc "Executes and reports the archive lifecycle."
  @spec lifecycle(Path.t(), Path.t(), keyword()) :: result()
  def lifecycle(payload_dir, prefix, opts \\ []) do
    execute(:archive, identity(payload_dir), %{
      install: fn state ->
        case install_payload(:archive, payload_dir, prefix, opts) do
          {:ok, install} -> {:ok, Map.put(state, :install, install), install_evidence(install, "archive")}
          {:error, reason} -> {:error, reason}
        end
      end,
      first_run: fn %{install: install} = state ->
        case first_run(install) do
          {:ok, evidence} -> {:ok, state, evidence}
          {:error, reason} -> {:error, reason}
        end
      end,
      update: fn %{install: install} = state ->
        case install_payload(:archive, payload_dir, install.root, opts) do
          {:ok, updated} ->
            evidence = identity_evidence("update", updated.payload_identity, %{"method" => "archive"})
            {:ok, Map.put(state, :install, updated), evidence}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      remove: fn %{install: install} = state ->
        case remove(install, opts) do
          {:ok, evidence} -> {:ok, state, evidence}
          {:error, reason} -> {:error, reason}
        end
      end
    })
  end

  @doc "Reads the identity that all channel results must report."
  @spec identity(Path.t()) :: {:ok, payload_identity()} | {:error, term()}
  def identity(payload_dir) do
    with {:ok, payload} <- read_json(Path.join(payload_dir, "payload.json")),
         archive when is_binary(archive) <- payload["archive"],
         {:ok, checksum} <- Payload.checksum(payload_dir, archive),
         {:ok, provenance} <- read_json(Path.join(payload_dir, "provenance.json")),
         version when is_binary(version) and version != "" <- payload["version"],
         license when is_binary(license) and license != "" <- payload["license"] do
      {:ok,
       %{
         "checksum" => checksum,
         "provenance" => provenance,
         "version" => version,
         "license" => license
       }}
    else
      nil -> {:error, :payload_identity_incomplete}
      false -> {:error, :payload_identity_incomplete}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Runs four owner-supplied stages and returns one common channel result."
  @spec execute(channel(), {:ok, payload_identity()} | {:error, term()}, map()) :: result()
  def execute(channel, {:ok, identity}, callbacks) when channel in @channels and is_map(callbacks) do
    {stages, _state} = execute_stages(@stages, callbacks, %{}, [])
    result(channel, identity, stages)
  end

  def execute(channel, {:error, reason}, _callbacks) when channel in @channels do
    stages = [failed_stage(:install, reason) | not_run_stages(tl(@stages))]
    result(channel, unavailable_identity(), stages)
  end

  @doc "Validates one complete owner result before matrix comparison."
  @spec validate_result(term(), channel()) :: :ok | {:error, term()}
  def validate_result(
        %{
          "schema" => "jido.channel-lifecycle",
          "schema_version" => 1,
          "channel" => channel_name,
          "status" => status,
          "payload_identity" => identity,
          "stages" => stages
        },
        channel
      )
      when channel in @channels and status in ["pass", "fail"] and is_map(identity) and is_list(stages) do
    with true <- channel_name == Atom.to_string(channel),
         true <- Enum.map(stages, & &1["stage"]) == @stage_names,
         true <- Enum.all?(stages, &valid_stage?/1),
         true <- valid_identity?(identity),
         true <- status_matches_stages?(status, stages) do
      :ok
    else
      false -> {:error, :invalid_channel_result}
    end
  end

  def validate_result(_result, _channel), do: {:error, :invalid_channel_result}

  @doc false
  @spec install_payload(channel(), Path.t(), Path.t(), keyword()) :: {:ok, install()} | {:error, term()}
  def install_payload(channel, payload_dir, root, opts) when channel in @channels do
    public_key = Keyword.get(opts, :public_key)

    with :ok <- require_public_key(public_key),
         {:ok, _report} <- Payload.verify(payload_dir, public_key: public_key),
         {:ok, identity} <- identity(payload_dir),
         {:ok, payload} <- read_json(Path.join(payload_dir, "payload.json")),
         :ok <- copy_payload(payload_dir, root, payload),
         {:ok, executable} <- installed_executable(root) do
      {:ok, %{channel: channel, root: root, executable: executable, payload_identity: identity}}
    end
  end

  @doc false
  @spec first_run(install()) :: {:ok, map()} | {:error, term()}
  def first_run(install) do
    identity = install.payload_identity

    with {:ok, output} <- exec_version(install.executable),
         true <- version_printed?(output, identity["version"]) do
      {:ok,
       identity_evidence("first_run", identity, %{
         "toolchain" => "bundled",
         "compiled" => false,
         "executable" => Path.relative_to(install.executable, install.root)
       })}
    else
      false -> {:error, :version_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec remove(install(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove(install, opts \\ []) do
    keep = Keyword.get(opts, :user_data, [])

    with {:ok, names} <- File.ls(install.root) do
      names
      |> Enum.reject(&(&1 in keep))
      |> Enum.each(fn name -> File.rm_rf!(Path.join(install.root, name)) end)

      {:ok,
       %{
         "stage" => "remove",
         "status" => "pass",
         "user_data" => keep,
         "root_exists" => File.dir?(install.root)
       }}
    end
  end

  @doc false
  @spec install_evidence(install(), String.t(), map()) :: map()
  def install_evidence(install, method, extra \\ %{}) do
    identity_evidence(
      "install",
      install.payload_identity,
      Map.merge(%{"method" => method, "root" => Path.basename(install.root)}, extra)
    )
  end

  @doc false
  @spec identity_evidence(String.t(), payload_identity(), map()) :: map()
  def identity_evidence(stage, identity, extra \\ %{}) do
    Map.merge(
      %{
        "stage" => stage,
        "status" => "pass",
        "checksum" => identity["checksum"],
        "version" => identity["version"],
        "license" => identity["license"]
      },
      extra
    )
  end

  defp execute_stages([], _callbacks, state, completed), do: {Enum.reverse(completed), state}

  defp execute_stages([stage | remaining], callbacks, state, completed) do
    expected_stage = Atom.to_string(stage)

    case Map.fetch!(callbacks, stage).(state) do
      {:ok, next_state, %{"stage" => ^expected_stage, "status" => "pass"} = evidence} ->
        execute_stages(remaining, callbacks, next_state, [evidence | completed])

      {:error, reason} ->
        stages = Enum.reverse(completed) ++ [failed_stage(stage, reason)] ++ not_run_stages(remaining)
        {stages, state}
    end
  end

  defp result(channel, identity, stages) do
    status = if Enum.all?(stages, &(&1["status"] == "pass")), do: "pass", else: "fail"

    %{
      "schema" => "jido.channel-lifecycle",
      "schema_version" => 1,
      "channel" => Atom.to_string(channel),
      "status" => status,
      "published" => false,
      "payload_identity" => identity,
      "stages" => stages,
      "summary" => Redaction.redact("#{channel} channel #{status}")
    }
  end

  defp failed_stage(stage, reason) do
    %{"stage" => Atom.to_string(stage), "status" => "fail", "reason" => inspect(reason)}
  end

  defp not_run_stages(stages) do
    Enum.map(stages, &%{"stage" => Atom.to_string(&1), "status" => "not_run"})
  end

  defp unavailable_identity do
    %{
      "checksum" => "unavailable",
      "provenance" => %{"status" => "unavailable"},
      "version" => "unavailable",
      "license" => "unavailable"
    }
  end

  defp valid_identity?(identity) do
    is_binary(identity["checksum"]) and identity["checksum"] != "" and
      is_map(identity["provenance"]) and is_binary(identity["version"]) and identity["version"] != "" and
      is_binary(identity["license"]) and identity["license"] != ""
  end

  defp valid_stage?(%{"stage" => stage, "status" => status}) do
    stage in @stage_names and status in ["pass", "fail", "not_run"]
  end

  defp valid_stage?(_stage), do: false

  defp status_matches_stages?("pass", stages), do: Enum.all?(stages, &(&1["status"] == "pass"))

  defp status_matches_stages?("fail", stages) do
    case Enum.drop_while(stages, &(&1["status"] == "pass")) do
      [%{"status" => "fail"} | remaining] -> Enum.all?(remaining, &(&1["status"] == "not_run"))
      _other -> false
    end
  end

  defp require_public_key(key) when is_binary(key) and byte_size(key) > 0, do: :ok
  defp require_public_key(_key), do: {:error, :trusted_public_key_required}

  defp copy_payload(payload_dir, root, payload) do
    File.mkdir_p!(root)

    Enum.each(
      ["release.json", "sbom.json", "provenance.json", "checksums.txt", "LICENSE", payload["archive"]],
      fn name ->
        source = Path.join(payload_dir, name)
        if File.regular?(source), do: File.cp!(source, Path.join(root, name))
      end
    )

    extract_archive(root, payload["archive"])
  end

  defp extract_archive(root, archive_name) when is_binary(archive_name) do
    archive = Path.join(root, archive_name)

    with {:ok, members} <- :erl_tar.table(String.to_charlist(archive), [:compressed]),
         :ok <- safe_tar_members(members),
         :ok <- :erl_tar.extract(String.to_charlist(archive), [:compressed, cwd: String.to_charlist(root)]) do
      :ok
    else
      {:error, reason} -> {:error, {:archive_extract_failed, reason}}
    end
  end

  defp extract_archive(_root, _archive_name), do: {:error, :archive_missing}

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

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end
end
