defmodule Jido.Cli.Release.Readiness do
  @moduledoc "Runs opt-in release-readiness checks without changing the normal development path."

  @secret_environment ~w(
    ANTHROPIC_API_KEY
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    GEMINI_API_KEY
    GOOGLE_API_KEY
    OPENAI_API_KEY
  )

  @checks ["baseline", "replay", "golden-task", "tui-layout", "tui-terminal"]

  @doc "Returns the available check names in their required order."
  @spec checks() :: [String.t()]
  def checks, do: @checks

  @doc "Runs one named readiness check."
  @spec run!(String.t(), keyword()) :: map()
  def run!("baseline", opts), do: baseline!(opts)
  def run!("replay", opts), do: replay!(opts)
  def run!("golden-task", opts), do: golden_task!(opts)
  def run!("tui-layout", opts), do: tui_layout!(opts)
  def run!("tui-terminal", opts), do: tui_terminal!(opts)
  def run!(name, _opts), do: raise(ArgumentError, "unknown release-readiness check: #{inspect(name)}")

  @doc false
  @spec baseline!(keyword()) :: map()
  def baseline!(opts \\ []) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    source = Keyword.get_lazy(opts, :source, fn -> source_identity!(project_root) end)
    runner = Keyword.get(opts, :baseline_runner, &run_clean_baseline!/4)

    runs =
      Enum.map(["run-a", "run-b"], fn run_id ->
        runner.(run_id, project_root, source, opts)
      end)

    [first, second] = Enum.map(runs, &Map.fetch!(&1, "summary"))

    if first != second do
      raise "clean release baselines differ"
    end

    %{
      "status" => "passed",
      "source" => source,
      "runs" => runs,
      "semantic_sha256" => digest(first)
    }
  end

  defp replay!(opts) do
    command_check!(
      "replay",
      [
        "test",
        "test/jido_cli/cli/automation/replay_test.exs",
        "test/jido_cli/cli/automation/jsonl_test.exs",
        "test/jido_cli/release/tooling_test.exs",
        "--seed",
        "0"
      ],
      opts
    )
  end

  defp golden_task!(opts) do
    command_check!(
      "golden-task",
      ["test", "test/integration/coding_scenario_oracle_test.exs", "--seed", "0"],
      opts
    )
  end

  defp tui_layout!(opts) do
    command_check!(
      "tui-layout",
      [
        "test",
        "test/jido_cli/cli/tui/editor_test.exs",
        "test/jido_cli/cli/tui/state_test.exs",
        "test/jido_cli/cli/tui/view_test.exs",
        "--seed",
        "0"
      ],
      opts
    )
  end

  defp tui_terminal!(opts) do
    command_check!(
      "tui-terminal",
      [
        "test",
        "test/integration/coding_tui_pty_test.exs",
        "test/jido_cli/cli/tui_test.exs",
        "--include",
        "expect",
        "--seed",
        "0",
        "--timeout",
        "180000"
      ],
      opts
    )
  end

  @doc false
  @spec source_identity!(Path.t(), function()) :: map()
  def source_identity!(project_root, runner \\ &System.cmd/3) do
    commit = git!(runner, project_root, ["rev-parse", "HEAD"])
    tree = git!(runner, project_root, ["rev-parse", "HEAD^{tree}"])
    status = git!(runner, project_root, ["status", "--porcelain", "--untracked-files=normal"])

    unless commit =~ ~r/\A[0-9a-f]{40}\z/ and tree =~ ~r/\A[0-9a-f]{40}\z/ do
      raise "release-readiness source identity is invalid"
    end

    if status != "", do: raise("release-readiness checks require a clean checkout")

    %{
      "commit" => commit,
      "tree" => tree,
      "mix_lock_sha256" => file_digest(Path.join(project_root, "mix.lock")),
      "toolchain" => %{
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "mix" => Application.spec(:mix, :vsn) |> to_string()
      }
    }
  end

  defp run_clean_baseline!(run_id, project_root, source, opts) do
    root = temporary_path("jido-readiness-#{run_id}")
    checkout = Path.join(root, "source")
    sibling = Path.join(root, "jidoka")
    pinned_jidoka = Path.join(project_root, "deps/jidoka")
    git_config = Path.join(root, "gitconfig")
    keep? = Keyword.get(opts, :keep_workspaces, false)
    File.mkdir_p!(root)
    File.write!(git_config, "")

    environment =
      [
        {"GIT_CONFIG_GLOBAL", git_config},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"MIX_ENV", nil}
      ] ++ Enum.map(@secret_environment, &{&1, nil})

    try do
      command!(
        "git",
        ["clone", "--no-hardlinks", "--quiet", "--no-checkout", project_root, checkout],
        root,
        environment
      )

      command!("git", ["checkout", "--quiet", source["commit"]], checkout, environment)

      command!(
        "git",
        ["clone", "--no-hardlinks", "--quiet", pinned_jidoka, sibling],
        root,
        environment
      )

      command!("git", ["checkout", "--quiet", Jido.Cli.Release.CrossRepo.pinned_ref!()], sibling, environment)
      command!("mix", ["jido.release", "--warm-runs", "1"], checkout, environment)

      acceptance =
        checkout
        |> Path.join("dist/acceptance.json")
        |> File.read!()
        |> Jason.decode!()

      %{"run" => run_id, "summary" => baseline_summary(acceptance)}
    after
      unless keep?, do: File.rm_rf!(root)
    end
  end

  defp baseline_summary(acceptance) do
    %{
      "status" => acceptance["status"],
      "archive_tested" => acceptance["archive_tested"],
      "live_provider_calls" => acceptance["live_provider_calls"],
      "gates" => acceptance["gates"],
      "commands" => acceptance["commands"],
      "tui" => acceptance["tui"],
      "read_only_installation" => acceptance["read_only_installation"],
      "coding_workflow" => acceptance["coding_workflow"],
      "categories" => %{
        "test" => "passed",
        "production_build" => "passed",
        "release" => "passed",
        "command" => "passed",
        "automation" => "passed",
        "artifact" => "passed",
        "exit_status" => "passed"
      }
    }
  end

  defp command!(command, args, directory, environment) do
    case System.cmd(command, args,
           cd: directory,
           env: environment,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_output, 0} -> :ok
      {_output, status} -> raise "#{command} #{Enum.join(args, " ")} failed with status #{status}"
    end
  end

  defp command_check!(name, args, opts) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    environment = Enum.map(@secret_environment, &{&1, nil})

    command_opts = [
      cd: project_root,
      env: environment,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, :line)
    ]

    case runner.("mix", args, command_opts) do
      {_output, 0} ->
        %{"status" => "passed", "command" => Enum.join(["mix" | args], " "), "check" => name}

      {_output, status} ->
        raise "release-readiness check #{name} failed with status #{status}"
    end
  end

  defp git!(runner, project_root, args) do
    case runner.("git", args, cd: project_root, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed with status #{status}: #{String.trim(output)}"
    end
  end

  defp file_digest(path), do: path |> File.read!() |> digest_binary()
  defp digest(value), do: value |> Jason.encode!() |> digest_binary()
  defp digest_binary(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp temporary_path(prefix) do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "#{prefix}-#{id}")
  end
end
