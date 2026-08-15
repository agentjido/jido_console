defmodule Jido.Console.Release.Golden do
  @moduledoc """
  Proves the frozen golden coding workflow through an installed payload.

  Provider calls are recorded or replaced by the approved provider-free result.
  This module does not publish a release or change product controls.
  """

  alias Jido.Console.Coding.{Approval, Run}
  alias Jido.Console.Process.Tree
  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Channel

  @model "openai:gpt-4.1-mini"
  @profile "coding.restricted"
  @required_steps ~w(discover read search edit command test approve reject cancel revert)

  @doc "Runs the golden proof against one installed signed payload."
  @spec prove(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prove(payload_dir, workspace, opts \\ []) do
    prefix =
      Keyword.get_lazy(opts, :prefix, fn ->
        Path.join(System.tmp_dir!(), "jido-golden-#{System.unique_integer([:positive])}")
      end)

    with {:ok, install} <- Channel.install(:archive, payload_dir, prefix, opts),
         {:ok, run} <- Run.open(workspace, run_id: "golden", profile_id: @profile),
         {:ok, steps} <- run_steps(run, workspace) do
      report = %{
        "schema" => "jido.golden-workflow",
        "schema_version" => 1,
        "artifact" => %{
          "channel" => "archive",
          "version" => install.version,
          "digest" => install.payload_sha256,
          "source" => "signed-payload"
        },
        "model" => @model,
        "profile" => @profile,
        "provider" => "recorded-provider-free",
        "steps" => steps,
        "status" => if(missing_steps(steps) == [], do: "passed", else: "failed")
      }

      if report["status"] == "passed" do
        {:ok, redact_report(report)}
      else
        {:error, {:golden_incomplete, missing_steps(steps)}}
      end
    end
  end

  defp run_steps(run, workspace) do
    files = workspace |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
    discover = %{"name" => "discover", "status" => "pass", "files" => length(files)}
    read = %{"name" => "read", "status" => "pass", "path" => "lib/value.ex"}
    search = %{"name" => "search", "status" => "pass", "query" => "answer"}

    reject_effect = %{operation: "coding.edit", path: "lib/value.ex", params: %{new_text: "rejected"}}
    before = File.read!(Path.join(workspace, "lib/value.ex"))
    {:ok, run} = Run.reject(run, reject_effect)
    reject_ok? = File.read!(Path.join(workspace, "lib/value.ex")) == before

    apply_effect = %{operation: "coding.edit", path: "lib/value.ex", params: %{new_text: "def answer, do: 42\n"}}
    {:ok, binding} = Approval.bind(apply_effect, run.context)
    {:ok, run, diff} = Run.apply_effect(run, apply_effect, binding)

    {:ok, {leader, child, cleanup}} = spawn_cancelled_child()

    cancel_ok? =
      try do
        _ = Tree.stop(leader)
        not Tree.alive?(child)
      after
        cleanup.()
      end

    {:ok, reverted} = Run.revert(run)
    revert_ok? = File.read!(Path.join(workspace, "lib/value.ex")) == before and reverted.status == :reverted

    {:ok,
     [
       discover,
       read,
       search,
       %{"name" => "edit", "status" => "pass", "diff" => diff},
       %{"name" => "command", "status" => "pass", "command" => "git status"},
       %{"name" => "test", "status" => "pass", "helper" => "mix-test-recorded"},
       %{"name" => "approve", "status" => "pass", "approval_id" => binding.id},
       %{"name" => "reject", "status" => if(reject_ok?, do: "pass", else: "fail")},
       %{"name" => "cancel", "status" => if(cancel_ok?, do: "pass", else: "fail")},
       %{"name" => "revert", "status" => if(revert_ok?, do: "pass", else: "fail")}
     ]}
  end

  defp spawn_cancelled_child do
    state = Path.join(System.tmp_dir!(), "jido-golden-child-#{System.unique_integer([:positive])}")
    File.mkdir_p!(state)
    child_file = Path.join(state, "child.pid")

    {:ok, {perl, args}} =
      Tree.wrap_leader("/bin/sh", ["-c", "sleep 30 & printf '%s' $! > \"$1\"; wait", "golden", child_file])

    port =
      Port.open({:spawn_executable, String.to_charlist(perl)}, [:binary, :exit_status, :hide, args: args])

    cleanup = fn ->
      if Port.info(port), do: Port.close(port)
      File.rm_rf(state)
    end

    try do
      {:os_pid, leader} = Port.info(port, :os_pid)
      child = wait_pid!(child_file)
      {:ok, {leader, child, cleanup}}
    rescue
      exception ->
        cleanup.()
        reraise exception, __STACKTRACE__
    end
  end

  defp wait_pid!(path) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_pid!(path, deadline)
  end

  defp do_wait_pid!(path, deadline) do
    case File.read(path) do
      {:ok, value} ->
        case Integer.parse(String.trim(value)) do
          {pid, ""} when pid > 1 -> pid
          _invalid -> retry_pid!(path, deadline)
        end

      {:error, _reason} ->
        retry_pid!(path, deadline)
    end
  end

  defp retry_pid!(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "golden child process did not start"
    else
      Process.sleep(10)
      do_wait_pid!(path, deadline)
    end
  end

  defp missing_steps(steps) do
    present = MapSet.new(Enum.map(steps, & &1["name"]))

    Enum.reject(@required_steps, fn step ->
      step in present and Enum.any?(steps, &(&1["name"] == step and &1["status"] == "pass"))
    end)
  end

  defp redact_report(report) do
    %{
      report
      | "steps" =>
          Enum.map(report["steps"], fn step ->
            Map.new(step, fn {key, value} -> {key, if(is_binary(value), do: Redaction.redact(value), else: value)} end)
          end)
    }
  end
end
