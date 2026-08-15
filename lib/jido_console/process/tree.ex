defmodule Jido.Console.Process.Tree do
  @moduledoc """
  Owns one restricted child-process tree.

  Descendants inherit no extra authority. The owner stops the complete tree on
  completion, rejection, cancel, timeout, and owner exit. Failed cleanup is a
  visible error and is not a safe completion.
  """

  @kill "/bin/kill"
  @ps "/bin/ps"
  @setsid "use POSIX qw(setsid); POSIX::setsid(); exec { $ARGV[0] } @ARGV"

  @type stop_result :: %{status: :stopped | :failed, leftover: non_neg_integer()}

  @doc "Wraps an executable so it becomes the process-group leader."
  @spec wrap_leader(String.t(), [String.t()]) :: {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def wrap_leader(executable, args) when is_binary(executable) and is_list(args) do
    case System.find_executable("perl") || existing_perl() do
      nil ->
        {:error, :process_tree_launcher_unavailable}

      perl ->
        {:ok, {perl, ["-e", @setsid, "--", executable | args]}}
    end
  end

  @doc "Watches the caller and stops the tree if that owner exits."
  @spec watch(pos_integer()) :: pid()
  def watch(os_pid) when is_integer(os_pid) and os_pid > 1 do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, ^owner, _reason} ->
          _ = stop(os_pid)

        :release ->
          :ok
      end
    end)
  end

  @doc "Releases an owner-exit watcher after a normal stop."
  @spec release(pid()) :: :ok
  def release(pid) when is_pid(pid) do
    send(pid, :release)
    :ok
  end

  @doc "Stops every remaining member of the process group."
  @spec stop(pos_integer()) :: {:ok, stop_result()} | {:error, term()}
  def stop(os_pid) when is_integer(os_pid) and os_pid > 1 do
    signal(os_pid, "-TERM")
    wait_empty(os_pid, 200)
    signal(os_pid, "-KILL")
    wait_empty(os_pid, 200)
    report(os_pid)
  end

  def stop(_os_pid), do: {:error, :invalid_process_tree}

  @doc "Lists living members of a process group without exposing them as evidence."
  @spec members(pos_integer()) :: [pos_integer()]
  def members(os_pid) when is_integer(os_pid) and os_pid > 1 do
    pgrep = System.find_executable("pgrep") || "/usr/bin/pgrep"

    case System.cmd(pgrep, ["-g", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {output, 0} -> parse_pids(output)
      {_output, _status} -> []
    end
  end

  @doc "Returns true when the OS process is still alive."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pid) when is_integer(pid) and pid > 1 do
    case System.cmd(@ps, ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {status, 0} -> not String.starts_with?(String.trim(status), "Z")
      {_output, _status} -> false
    end
  end

  @doc "Removes process-local temporary state after the tree is stopped."
  @spec cleanup_temp(String.t()) :: :ok | {:error, term()}
  def cleanup_temp(path) when is_binary(path) do
    case File.rm_rf(path) do
      {:ok, _paths} -> :ok
      {:error, reason, _file} -> {:error, {:temp_cleanup_failed, reason}}
    end
  end

  @doc "Projects a redacted cleanup record."
  @spec evidence(stop_result()) :: map()
  def evidence(result) do
    %{
      "status" => Atom.to_string(result.status),
      "cleanup" => if(result.leftover == 0, do: "confirmed", else: "failed")
    }
  end

  defp report(os_pid) do
    leftover = length(members(os_pid))

    if leftover == 0 do
      {:ok, %{status: :stopped, leftover: 0}}
    else
      {:error, {:cleanup_failed, leftover}}
    end
  end

  defp signal(os_pid, name) do
    _result = System.cmd(@kill, [name, "-" <> Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp wait_empty(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_empty(os_pid, deadline)
  end

  defp do_wait_empty(os_pid, deadline) do
    cond do
      members(os_pid) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        do_wait_empty(os_pid, deadline)
    end
  end

  defp parse_pids(output) do
    output
    |> String.split()
    |> Enum.flat_map(fn token ->
      case Integer.parse(token) do
        {pid, ""} when pid > 1 -> [pid]
        _invalid -> []
      end
    end)
  end

  defp existing_perl do
    if File.regular?("/usr/bin/perl"), do: "/usr/bin/perl"
  end
end
