defmodule Jido.Console.Release.Readiness do
  @moduledoc "Runs opt-in release-readiness checks without changing the normal development path."

  @secret_environment ~w(
    ANTHROPIC_API_KEY
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    GEMINI_API_KEY
    GOOGLE_API_KEY
    OPENAI_API_KEY
  )

  @checks [
    "baseline",
    "replay",
    "golden-task",
    "tui-layout",
    "tui-terminal",
    "file-boundary",
    "runtime-boundary",
    "measurement",
    "support-policy",
    "dependency-policy",
    "source-policy",
    "workflow-policy",
    "delivery-plan",
    "delivery-trace"
  ]

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
  def run!("file-boundary", opts), do: Jido.Console.Release.Boundaries.file_boundary!(opts)
  def run!("runtime-boundary", opts), do: Jido.Console.Release.Boundaries.runtime_boundary!(opts)
  def run!("measurement", opts), do: measurement!(opts)
  def run!("support-policy", opts), do: support_policy!(opts)
  def run!("dependency-policy", opts), do: dependency_policy!(opts)
  def run!("source-policy", opts), do: source_policy!(opts)
  def run!("workflow-policy", opts), do: workflow_policy!(opts)
  def run!("delivery-plan", opts), do: delivery_plan!(opts)
  def run!("delivery-trace", opts), do: Jido.Console.Release.Traceability.run!(opts)
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
        "test/jido_console/cli/automation/replay_test.exs",
        "test/jido_console/cli/automation/jsonl_test.exs",
        "test/jido_console/release/tooling_test.exs",
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
        "test/jido_console/cli/tui/editor_test.exs",
        "test/jido_console/cli/tui/state_test.exs",
        "test/jido_console/cli/tui/view_test.exs",
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
        "test/jido_console/cli/tui_test.exs",
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

  @doc false
  @spec measurement!(keyword()) :: map()
  def measurement!(opts \\ []) do
    collector = Keyword.get(opts, :measurement_collector, &collect_measurement!/1)
    result = collector.(opts)

    required = ~w(package_size_bytes help version first_frame runtime_ready idle_memory_kib)

    unless result["status"] == "passed" and Enum.all?(required, &Map.has_key?(result, &1)) do
      raise "release measurement is incomplete"
    end

    Map.put(result, "claim", "environment-specific release data; not a public performance claim")
  end

  @doc false
  @spec support_policy!(keyword()) :: map()
  def support_policy!(opts \\ []) do
    policy!(
      opts,
      "roadmap/milestones/00-establish-release-readiness/first-user-support.md",
      ~w(Status User Job Activation Product Platform Channel Provider Security Non-claims)
    )
  end

  @doc false
  @spec dependency_policy!(keyword()) :: map()
  def dependency_policy!(opts \\ []) do
    command_check!(
      "dependency-policy",
      [
        "test",
        "test/jido_console/jidoka_dependency_test.exs",
        "test/jido_console/jidoka_public_api_boundary_test.exs",
        "test/jido_console/release/cross_repo_test.exs",
        "--seed",
        "0"
      ],
      opts
    )
  end

  @doc false
  @spec source_policy!(keyword()) :: map()
  def source_policy!(opts \\ []) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()

    result =
      policy!(
        opts,
        "roadmap/milestones/00-establish-release-readiness/tilde-source-governance.md",
        ~w(Status Source Attribution Approved Prohibited)
      )

    dependency_source =
      ["mix.exs", "mix.lock"]
      |> Enum.map_join("\n", fn path -> File.read!(Path.join(project_root, path)) end)

    production_source =
      project_root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    if Regex.match?(~r/(?:^|[^a-z0-9_])tilde(?:[^a-z0-9_]|$)/i, dependency_source) do
      raise "Tilde is present in the dependency definition"
    end

    if Regex.match?(~r/\bTilde(?:\.|\b)/, production_source) do
      raise "production source references a Tilde module"
    end

    Map.merge(result, %{"dependency" => "absent", "production_module" => "absent"})
  end

  @doc false
  @spec workflow_policy!(keyword()) :: map()
  def workflow_policy!(opts \\ []) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    files = Path.wildcard(Path.join(project_root, ".github/workflows/*.{yml,yaml}")) |> Enum.sort()

    if files == [], do: raise("no GitHub workflows found")

    sources = Enum.map(files, &{Path.relative_to(&1, project_root), File.read!(&1)})

    uses =
      for {file, source} <- sources,
          [_match, target] <- Regex.scan(~r/^\s*uses:\s*([^\s#]+)/m, source),
          not String.starts_with?(target, "./") do
        {file, target}
      end

    references =
      Enum.map(uses, fn {file, target} ->
        case String.split(target, "@", parts: 2) do
          [_action, reference] -> {file, reference}
          _other -> raise "#{file} uses an external action without an immutable reference"
        end
      end)

    case Enum.find(references, fn {_file, reference} ->
           not Regex.match?(~r/\A[0-9a-f]{40}\z/, reference)
         end) do
      nil -> :ok
      {file, reference} -> raise "#{file} uses mutable workflow reference #{reference}"
    end

    joined = Enum.map_join(sources, "\n", &elem(&1, 1))
    normalized = String.downcase(joined)

    if Regex.match?(~r/^\s*secrets:\s*inherit\s*$/m, joined) do
      raise "workflow uses unrestricted secret inheritance"
    end

    forbidden = [
      "jido.release.audit",
      "actions/upload-artifact",
      "softprops/action-gh-release",
      "gh release",
      "mix hex.publish"
    ]

    case Enum.find(forbidden, &String.contains?(normalized, &1)) do
      nil -> :ok
      value -> raise "workflow contains release-only operation #{value}"
    end

    %{
      "status" => "passed",
      "workflow_count" => length(files),
      "immutable_reference_count" => length(references),
      "secret_inheritance" => "absent",
      "release_operations" => "absent"
    }
  end

  @doc false
  @spec delivery_plan!(keyword()) :: map()
  def delivery_plan!(opts \\ []) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    relative_path = "roadmap/milestones/01-ship-trustworthy-local-kernel/delivery-plan.json"
    plan = project_root |> Path.join(relative_path) |> File.read!() |> Jason.decode!()
    critical_path = plan["critical_path"] || []
    required_fields = get_in(plan, ["beadwork", "required_fields"]) || %{}

    checks = [
      {plan["schema"] == "jido.release.delivery-plan", "schema"},
      {get_in(plan, ["milestone", "url"]) == "https://github.com/agentjido/jido_console/milestone/1",
       "GitHub milestone"},
      {get_in(plan, ["beadwork", "source_of_truth"]) == true, "Beadwork source"},
      {get_in(plan, ["beadwork", "label"]) == "milestone-1", "Beadwork label"},
      {get_in(plan, ["items", "prefix"]) == "jido_console-m1e", "item prefix"},
      {get_in(plan, ["items", "count"]) == 30, "item count"},
      {Map.keys(required_fields) |> Enum.sort() ==
         ~w(dependencies effort_class owner proof_artifact readiness_state target_release), "required fields"},
      {List.first(critical_path) == "jido_console-g0e15", "critical path entry"},
      {List.last(critical_path) == "jido_console-m1e30", "critical path release"},
      {Enum.uniq(critical_path) == critical_path, "critical path uniqueness"}
    ]

    case Enum.find(checks, fn {passed, _name} -> not passed end) do
      nil -> %{"status" => "passed", "plan" => relative_path}
      {_passed, name} -> raise "Milestone 1 delivery plan is invalid at: #{name}"
    end
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

      command!("git", ["checkout", "--quiet", Jido.Console.Release.CrossRepo.pinned_ref!()], sibling, environment)
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

  defp collect_measurement!(opts) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    source = source_identity!(project_root)
    environment = Enum.map(@secret_environment, &{&1, nil})
    command!("mix", ["jido.release", "--warm-runs", "20"], project_root, environment)

    acceptance = project_root |> Path.join("dist/acceptance.json") |> File.read!() |> Jason.decode!()
    archive = Path.join(project_root, "dist/#{acceptance["artifact"]}")
    idle_memory = idle_memory_samples!(archive, 6)

    %{
      "status" => "passed",
      "source" => source,
      "artifact" => %{
        "name" => acceptance["artifact"],
        "sha256" => acceptance["sha256"],
        "target" => acceptance["target"],
        "version" => acceptance["version"]
      },
      "package_size_bytes" => File.stat!(archive).size,
      "help" => acceptance["startup"]["help"],
      "version" => acceptance["startup"]["version"],
      "first_frame" => acceptance["startup"]["first_frame"],
      "runtime_ready" => acceptance["startup"]["runtime_ready"],
      "idle_memory_kib" => %{
        "cold" => hd(idle_memory),
        "warm_samples" => tl(idle_memory),
        "unit" => "KiB"
      },
      "method" => %{
        "command" => "mix jido.release --warm-runs 20",
        "sample_count" => 21,
        "memory_sample_count" => 6,
        "summary" => "one cold sample followed by warm samples"
      }
    }
  end

  defp idle_memory_samples!(archive, count) do
    root = temporary_path("jido-measurement")
    File.mkdir_p!(root)

    try do
      File.cd!(root, fn ->
        case :erl_tar.extract(String.to_charlist(archive), [:compressed]) do
          :ok -> :ok
          {:error, reason} -> raise "cannot extract release for memory measurement: #{inspect(reason)}"
        end
      end)

      case Path.wildcard(Path.join(root, "*/bin/jido")) do
        [bin] -> measure_idle_memory!(bin, count)
        paths -> raise "release archive has #{length(paths)} jido executables"
      end
    after
      File.rm_rf!(root)
    end
  end

  defp measure_idle_memory!(bin, count) do
    expect = System.find_executable("expect") || raise "release measurement requires expect"

    script = """
    set timeout 12
    set stty_init "rows 30 columns 100"
    log_user 0
    for {set index 0} {$index < $env(JIDO_SAMPLE_COUNT)} {incr index} {
      spawn -noecho $env(JIDO_BIN)
      expect {
        -re {idle .* Enter sends} {}
        timeout {exit 2}
        eof {exit 3}
      }
      puts "rss_kib=[string trim [exec /bin/ps -o rss= -p [exp_pid]]]"
      send "\\033"
      expect eof
    }
    """

    {output, status} =
      System.cmd(
        "/usr/bin/env",
        [
          "-i",
          "PATH=/usr/bin:/bin",
          "LANG=C.UTF-8",
          "LC_ALL=C.UTF-8",
          "TERM=xterm-256color",
          "JIDO_BIN=#{bin}",
          "JIDO_SAMPLE_COUNT=#{count}",
          expect,
          "-c",
          script
        ],
        stderr_to_stdout: true
      )

    samples = Regex.scan(~r/rss_kib=(\d+)/, output) |> Enum.map(fn [_all, value] -> String.to_integer(value) end)

    if status != 0 or length(samples) != count do
      raise "idle-memory measurement failed with status #{status}"
    end

    samples
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

  defp policy!(opts, relative_path, required_terms) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    path = Path.join(project_root, relative_path)
    contents = File.read!(path)

    missing = Enum.reject(required_terms, &String.contains?(contents, &1))
    if missing != [], do: raise("#{relative_path} is missing: #{Enum.join(missing, ", ")}")

    %{"status" => "passed", "policy" => relative_path}
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
