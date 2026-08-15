defmodule Jido.Console.Coding.Local.Adapter do
  @moduledoc false

  @behaviour Jidoka.ExecutionEnvironment.Adapter

  alias Jido.Console.Coding.{Environment, Network}
  alias Jido.Console.Process.Tree
  alias Jidoka.Cancellation
  alias Jidoka.CodingPack.Workspace
  alias Jidoka.ExecutionEnvironment.{Binding, EnforcementEvidence}

  @adapter_id "jido_console.local_folder"
  @adapter_version "1"
  @shell "/bin/sh"
  @head "/usr/bin/head"
  @mkfifo "/usr/bin/mkfifo"
  # Git and other helpers get no network, including loopback. Mix still needs
  # localhost for local process coordination; bind and inbound stay on localhost.
  @git_sandbox_profile """
  (version 1)
  (allow default)
  (deny network*)
  """
  @mix_sandbox_profile """
  (version 1)
  (allow default)
  (deny network*)
  (allow network-bind (local ip "localhost:*"))
  (allow network-inbound (local ip "localhost:*"))
  (allow network-outbound (remote ip "localhost:*"))
  """
  @poll_interval_ms 50
  @termination_grace_ms 500

  @impl true
  def open(profile, _request, opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    binding =
      Binding.new!(
        adapter_id: profile.adapter_id,
        adapter_version: @adapter_version,
        profile_id: profile.profile_id,
        profile_digest: profile.digest,
        resource_ref: "local-folder-" <> String.replace_prefix(workspace.root_digest, "sha256:", ""),
        revision: 0,
        state: :available
      )

    {:ok, binding, evidence(opts)}
  end

  @impl true
  def acquire(binding, opts) do
    {:ok, %{resource_ref: binding.resource_ref}, evidence(opts)}
  end

  @impl true
  def execute(_handle, request, opts) when is_map(request) do
    with :ok <- validate_request(request),
         {:ok, _decision} <- Network.admit(request, opts),
         %Workspace{} = workspace <- Keyword.fetch!(opts, :workspace),
         {:ok, cwd} <- Workspace.resolve(workspace, request["cwd"], type: :directory),
         {:ok, executable} <- executable(request["command"], opts),
         {:ok, result} <- run(executable, request["args"], cwd.absolute, request, opts) do
      {:ok, result, execute_evidence(request, opts)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :local_coding_request_invalid}
    end
  end

  @impl true
  def checkpoint(_handle, _binding, _opts), do: {:error, :checkpoint_unsupported}

  @impl true
  def restore(_binding, _checkpoint, _opts), do: {:error, :restore_unsupported}

  @impl true
  def fork(_binding, _checkpoint, _opts), do: {:error, :fork_unsupported}

  @impl true
  def close(_handle, opts), do: {:ok, evidence(opts)}

  @impl true
  def cleanup(_binding, opts), do: {:ok, evidence(opts)}

  defp validate_request(request) do
    case Zoi.parse(request_schema(), request) do
      {:ok, request} -> validate_request_text(request)
      {:error, errors} -> {:error, {:local_coding_request_invalid, Zoi.treefy_errors(errors)}}
    end
  end

  defp validate_request_text(request) do
    values = [request["command_class"], request["cwd"] | request["args"]]

    if Enum.all?(values, &(String.valid?(&1) and not String.contains?(&1, <<0>>))),
      do: :ok,
      else: {:error, :local_coding_request_text_invalid}
  end

  defp request_schema do
    Zoi.map(
      %{
        "args" => Zoi.array(Zoi.string()),
        "command" => Zoi.enum(["git", "mix"]),
        "command_class" => Jido.Console.Document.non_empty_string(),
        "cwd" => Jido.Console.Document.non_empty_string(),
        "max_output_bytes" => Zoi.integer() |> Zoi.positive(),
        "mutation" => Zoi.enum(["read"]),
        "network" => Zoi.enum([false]),
        "stdin" => Zoi.enum([""]),
        "timeout_ms" => Zoi.integer() |> Zoi.positive()
      },
      unrecognized_keys: :error
    )
  end

  defp executable(command, opts) do
    case opts |> Keyword.fetch!(:executables) |> Map.fetch(command) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      :error -> {:error, :command_unavailable}
    end
  end

  defp run(executable, args, cwd, request, opts) do
    started = System.monotonic_time(:millisecond)
    temporary_id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    with {:ok, prepared} <- prepare_command_env(opts) do
      temporary = Path.join(prepared.tmpdir, "jido-cli-command-#{temporary_id}")
      fifo = Path.join(temporary, "output.fifo")
      output_path = Path.join(temporary, "output")
      File.mkdir_p!(temporary)

      try do
        with {:ok, sandbox} <- sandbox_executable(opts),
             {:ok, port} <-
               open_port(
                 sandbox,
                 executable,
                 args,
                 cwd,
                 fifo,
                 output_path,
                 request["max_output_bytes"] + 1,
                 prepared.env,
                 request["command"]
               ),
             {:ok, os_pid} <- os_pid(port) do
          watch = Tree.watch(os_pid)

          try do
            outcome = await(port, request["timeout_ms"], request["max_output_bytes"], opts)
            captured = read_capture(output_path, request["max_output_bytes"])
            duration = max(System.monotonic_time(:millisecond) - started, 0)

            case Tree.stop(os_pid) do
              {:ok, _stopped} -> normalize_outcome(outcome, captured, duration)
              {:error, reason} -> {:error, {:process_tree_cleanup_failed, reason}}
            end
          after
            Tree.release(watch)
            _ = Tree.stop(os_pid)
          end
        end
      after
        _ = Tree.cleanup_temp(temporary)
      end
    end
  end

  defp prepare_command_env(opts) do
    with {:ok, %{env: env}} <- Environment.build(opts) do
      {:ok,
       %{
         env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end),
         tmpdir: Keyword.get(opts, :temporary_root, env["TMPDIR"])
       }}
    end
  end

  defp open_port(sandbox, executable, args, cwd, fifo, output_path, capture_limit, env, command) do
    script = ~S"""
    reap() {
      for pid in $(ps -o pid= -g $$ 2>/dev/null); do
        if [ "$pid" -ne "$$" ]; then
          kill -KILL "$pid" 2>/dev/null
        fi
      done
    }
    reader_pid=
    command_pid=
    trap 'trap - TERM INT HUP; reap; exit 143' TERM INT HUP
    fifo=$2
    "$1" "$2" || exit 125
    "$3" -c "$4" < "$2" > "$5" &
    reader_pid=$!
    shift 5
    "$@" > "$fifo" 2>&1 &
    command_pid=$!
    wait "$command_pid"
    command_status=$?
    wait "$reader_pid"
    reader_status=$?
    trap - TERM INT HUP
    reap
    if [ "$reader_status" -ne 0 ]; then exit 126; fi
    exit "$command_status"
    """

    shell_args = [
      "-c",
      script,
      "jido-cli",
      @mkfifo,
      fifo,
      @head,
      Integer.to_string(capture_limit),
      output_path,
      sandbox,
      "-p",
      sandbox_profile(command),
      executable | args
    ]

    case Tree.wrap_leader(@shell, shell_args) do
      {:ok, {leader, leader_args}} ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(leader)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              :use_stdio,
              args: leader_args,
              cd: String.to_charlist(cwd),
              env: env
            ]
          )

        {:ok, port}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {:local_command_start_failed, exception.__struct__}}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 1 -> {:ok, pid}
      _missing -> {:error, :process_tree_missing}
    end
  end

  defp sandbox_executable(opts) do
    case opts |> Keyword.fetch!(:executables) |> Map.fetch("sandbox-exec") do
      {:ok, path} when is_binary(path) -> {:ok, path}
      _missing -> {:error, :local_coding_sandbox_unavailable}
    end
  end

  defp sandbox_profile("mix"), do: @mix_sandbox_profile
  defp sandbox_profile(_command), do: @git_sandbox_profile

  defp await(port, timeout_ms, output_limit, opts) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_until(port, deadline, output_limit, opts, [], 0)
  end

  defp await_until(port, deadline, output_limit, opts, chunks, size) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Cancellation.check(opts) == {:error, :cancelled} ->
        stop_port(port)
        {:cancelled, output(chunks)}

      remaining <= 0 ->
        stop_port(port)
        {:timeout, output(chunks)}

      true ->
        receive do
          {^port, {:data, data}} ->
            collect(port, data, deadline, output_limit, opts, chunks, size)

          {^port, {:exit_status, exit_status}} ->
            {:ok, exit_status, output(chunks)}
        after
          min(remaining, @poll_interval_ms) ->
            await_until(port, deadline, output_limit, opts, chunks, size)
        end
    end
  end

  defp collect(port, data, deadline, output_limit, opts, chunks, size) do
    available = output_limit - size

    if byte_size(data) <= available do
      await_until(
        port,
        deadline,
        output_limit,
        opts,
        [data | chunks],
        size + byte_size(data)
      )
    else
      prefix = if available > 0, do: binary_part(data, 0, available), else: ""
      stop_port(port)
      {:output_limit, output([prefix | chunks])}
    end
  end

  defp stop_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> _ = Tree.stop(pid)
      _missing -> :ok
    end

    await_port_stop(port, System.monotonic_time(:millisecond) + @termination_grace_ms)
    if not is_nil(Port.info(port)), do: Port.close(port)
    drain_port(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp await_port_stop(port, deadline) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, _message} -> await_port_stop(port, deadline)
    after
      10 ->
        if not is_nil(Port.info(port)) and System.monotonic_time(:millisecond) < deadline,
          do: await_port_stop(port, deadline),
          else: :ok
    end
  end

  defp drain_port(port) do
    receive do
      {^port, _message} -> drain_port(port)
    after
      0 -> :ok
    end
  end

  defp read_capture(path, limit) do
    case File.read(path) do
      {:ok, content} ->
        {content, truncated} = cap(content, limit)
        %{content: content, truncated: truncated}

      {:error, :enoent} ->
        %{content: "", truncated: false}

      {:error, _reason} ->
        %{content: "", truncated: false}
    end
  end

  defp normalize_outcome({:ok, exit_status, diagnostics}, captured, duration) do
    stdout = captured_output(captured.content, diagnostics)

    if captured.truncated do
      {:ok, terminal_result("error", duration, stdout, true)}
    else
      {:ok,
       %{
         "status" => if(exit_status == 0, do: "ok", else: "nonzero"),
         "stdout" => stdout,
         "stderr" => "",
         "exit_status" => exit_status,
         "duration_ms" => duration,
         "stdout_truncated" => false,
         "stderr_truncated" => false
       }}
    end
  end

  defp normalize_outcome({:timeout, diagnostics}, captured, duration),
    do: {:ok, terminal_result("timeout", duration, captured_output(captured.content, diagnostics), false)}

  defp normalize_outcome({:cancelled, diagnostics}, captured, duration),
    do: {:ok, terminal_result("cancelled", duration, captured_output(captured.content, diagnostics), false)}

  defp normalize_outcome({:output_limit, diagnostics}, captured, duration),
    do: {:ok, terminal_result("error", duration, captured_output(captured.content, diagnostics), true)}

  defp captured_output("", diagnostics), do: diagnostics
  defp captured_output(content, _diagnostics), do: content

  defp terminal_result(status, duration, stdout, truncated) do
    %{
      "status" => status,
      "stdout" => stdout,
      "stderr" => "",
      "exit_status" => nil,
      "duration_ms" => duration,
      "stdout_truncated" => truncated,
      "stderr_truncated" => false
    }
  end

  defp execute_evidence(request, opts) do
    evidence(opts,
      applied_limits: %{
        "wall_time_ms" => request["timeout_ms"],
        "output_bytes" => request["max_output_bytes"]
      },
      facts: %{
        "shell_execute" => true,
        "cwd_confined" => true,
        "wall_timeout" => true,
        "output_limit" => true,
        "cancellation" => true,
        "command_class" => request["command_class"]
      }
    )
  end

  defp evidence(opts, overrides \\ []) do
    limits = %{
      "wall_time_ms" => Keyword.get(overrides, :wall_time_ms, 120_000),
      "output_bytes" => Keyword.get(overrides, :output_bytes, 262_144)
    }

    EnforcementEvidence.new!(
      status: :confirmed,
      adapter_id: @adapter_id,
      backend: "local-process",
      isolation: :process,
      network: :disabled,
      workspace: :persistent,
      applied_limits: Keyword.get(overrides, :applied_limits, limits),
      observed_at_ms: Keyword.get(opts, :observed_at_ms, System.system_time(:millisecond)),
      facts: Keyword.get(overrides, :facts, %{})
    )
  end

  defp output(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary() |> utf8_prefix()

  defp cap(value, limit) when byte_size(value) <= limit, do: {utf8_prefix(value), false}
  defp cap(value, limit), do: {utf8_prefix(value, limit), true}

  defp utf8_prefix(value) do
    if String.valid?(value), do: value, else: utf8_prefix(value, byte_size(value) - 1)
  end

  defp utf8_prefix(_value, limit) when limit <= 0, do: ""

  defp utf8_prefix(value, limit) do
    candidate = binary_part(value, 0, limit)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(value, limit - 1)
  end
end
