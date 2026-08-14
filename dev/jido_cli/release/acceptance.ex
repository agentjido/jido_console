defmodule Jido.Cli.Release.Acceptance do
  @moduledoc "Validates and benchmarks the exact final release archive."

  alias CodingScenario.Oracle
  alias Jido.Cli.Release.{Artifact, Contract, CrossRepo}

  @warm_runs 20
  @limits_ms %{
    "help" => 500.0,
    "version" => 500.0,
    "first_frame" => 500.0,
    "runtime_ready" => 1_250.0
  }
  @doc "Runs all automated gates and writes acceptance.json beside the archive."
  @spec run!(Path.t(), keyword()) :: map()
  def run!(archive, opts \\ []) do
    archive = Path.expand(archive)
    expected_version = Keyword.fetch!(opts, :version)
    expected_target = Keyword.get(opts, :target, "darwin-arm64")
    expected_sha256 = Keyword.fetch!(opts, :sha256)
    output = Keyword.get(opts, :output, Path.join(Path.dirname(archive), "acceptance.json"))
    warm_runs = Keyword.get(opts, :warm_runs, @warm_runs)
    limits = Keyword.get(opts, :limits_ms, @limits_ms)
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    gate!("archive checksum", fn ->
      actual = Artifact.sha256_file(archive)
      if actual != expected_sha256, do: raise("expected #{expected_sha256}, got #{actual}")
    end)

    isolation = Path.join(System.tmp_dir!(), "jido acceptance spaces-µ-#{System.unique_integer([:positive])}")
    File.mkdir_p!(isolation)

    try do
      root = extract_archive!(archive, isolation, expected_version, expected_target)
      metadata = root |> Path.join("release.json") |> File.read!() |> Jason.decode!()
      bin = Path.join(root, "bin/jido")

      gate!("metadata contract", fn ->
        :ok = Contract.validate_metadata(metadata)
        :ok = Contract.validate_layout(root, metadata)

        if metadata["version"] != expected_version, do: raise("wrong metadata version")
        if metadata["target"] != expected_target, do: raise("wrong metadata target")

        if get_in(metadata, ["runtime", "jidoka_ref"]) != CrossRepo.pinned_ref!(),
          do: raise("artifact Jidoka ref does not match the tested dependency pin")
      end)

      gate!("internal file inventory", fn -> validate_file_inventory!(root, metadata) end)
      gate!("private runtime", fn -> validate_private_runtime!(root, metadata) end)
      gate!("notices and evidence", fn -> validate_evidence!(archive, metadata, expected_sha256) end)

      startup = gate!("startup performance", fn -> startup_evidence!(bin, warm_runs, limits) end)
      commands = gate!("packaged commands", fn -> command_evidence!(bin, root, expected_version) end)
      tui = gate!("paint-first TUI", fn -> tui_evidence!(bin, isolation) end)
      read_only = gate!("read-only installation", fn -> read_only_evidence!(root, bin, expected_version) end)

      coding =
        gate!("external coding workflow", fn ->
          coding_workflow_evidence!(root, bin, isolation)
        end)

      evidence = %{
        "schema" => "jido.acceptance",
        "schema_version" => 1,
        "status" => "passed",
        "started_at" => started_at,
        "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "artifact" => Path.basename(archive),
        "sha256" => expected_sha256,
        "version" => expected_version,
        "target" => expected_target,
        "jidoka_ref" => metadata["runtime"]["jidoka_ref"],
        "archive_tested" => true,
        "isolated_path_features" => ["spaces", "non_ascii"],
        "path" => %{"value" => "/usr/bin:/bin", "erl" => false, "elixir" => false, "mix" => false},
        "live_provider_calls" => false,
        "startup" => startup,
        "commands" => commands,
        "tui" => tui,
        "read_only_installation" => read_only,
        "coding_workflow" => coding,
        "gates" => [
          "archive checksum",
          "metadata contract",
          "internal file inventory",
          "private runtime",
          "notices and evidence",
          "startup performance",
          "packaged commands",
          "paint-first TUI",
          "read-only installation",
          "external coding workflow"
        ]
      }

      write_json!(output, evidence)
      evidence
    after
      make_writable(isolation)
      File.rm_rf!(isolation)
    end
  end

  @doc "Returns cold, median, and 95th-percentile values for millisecond samples."
  @spec statistics!([number()]) :: map()
  def statistics!([cold | warm]) when warm != [] do
    sorted = Enum.sort(warm)
    count = length(sorted)
    middle = div(count, 2)

    median =
      if rem(count, 2) == 0,
        do: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2,
        else: Enum.at(sorted, middle) / 1

    p95_index = max(ceil(0.95 * count) - 1, 0)

    %{
      "cold_ms" => round_ms(cold),
      "warm_runs" => count,
      "warm_median_ms" => round_ms(median),
      "warm_p95_ms" => round_ms(Enum.at(sorted, p95_index)),
      "warm_samples_ms" => Enum.map(warm, &round_ms/1)
    }
  end

  defp startup_evidence!(bin, warm_runs, limits) when warm_runs > 0 do
    help = command_samples(bin, ["--help"], warm_runs + 1)
    version = command_samples(bin, ["--version"], warm_runs + 1)
    {first_frame, runtime_ready} = tui_samples(bin, warm_runs + 1)

    stats = %{
      "help" => statistics!(help),
      "version" => statistics!(version),
      "first_frame" => statistics!(first_frame),
      "runtime_ready" => statistics!(runtime_ready)
    }

    Enum.each(stats, fn {name, values} ->
      limit = Map.fetch!(limits, name)

      if values["warm_median_ms"] > limit do
        raise "#{name} warm median #{values["warm_median_ms"]} ms exceeds #{limit} ms"
      end
    end)

    if Enum.zip(first_frame, runtime_ready) |> Enum.any?(fn {first, ready} -> first >= ready end) do
      raise "first frame did not precede runtime readiness"
    end

    Map.put(stats, "limits_ms", limits)
  end

  defp command_evidence!(bin, root, version) do
    checks = [
      {"version", ["--version"], 0, "jido #{version}"},
      {"help", ["--help"], 0, "Usage:"},
      {"run_help", ["run", "--help"], 0, "Run options:"},
      {"eval_help", ["eval", "--help"], 0, "Eval options:"},
      {"execution_error", ["--release-unknown-option"], 1, "unknown option"},
      {"usage_error", ["run"], 64, "--agent"}
    ]

    results =
      Enum.map(checks, fn {name, args, status, text} ->
        {output, actual_status} = run_command(bin, args)

        if actual_status != status, do: raise("#{name} returned #{actual_status}, expected #{status}: #{output}")
        unless String.contains?(output, text), do: raise("#{name} output did not contain #{inspect(text)}")
        %{"name" => name, "status" => status}
      end)

    suite = Path.join(root, "share/jido/offline/suite.yml")
    {output, status} = run_command(bin, ["eval", suite])

    if status != 0 or not String.contains?(output, ~s("status":"matched")) do
      raise "offline replay failed with status #{status}: #{output}"
    end

    {native_output, native_status} =
      run_command(bin, [], %{"JIDO_RELEASE_NATIVE_PROBE" => "1"})

    if native_status != 0 or not String.contains?(native_output, "native probe passed") do
      raise "native library probe failed with status #{native_status}: #{native_output}"
    end

    results ++
      [
        %{"name" => "provider_free_offline_replay", "status" => 0, "matched" => true},
        %{"name" => "native_library_load", "status" => 0}
      ]
  end

  defp tui_evidence!(bin, isolation) do
    log = Path.join(isolation, "queued-turn.log")

    success_script = """
    set timeout 12
    log_user 0
    spawn -noecho $env(JIDO_BIN)
    expect {
      -re {Jido} {}
      timeout {puts "missing first frame"; exit 2}
      eof {puts "early exit before first frame"; exit 3}
    }
    after 50
    send "release probe\r"
    expect {
      -re {prompt queued} {}
      timeout {puts "missing queued prompt"; exit 4}
      eof {puts "early exit before queued prompt"; exit 5}
    }
    expect {
      -re {Release probe completed\.} {}
      timeout {puts "missing probe result"; exit 6}
      eof {puts "early exit before probe result"; exit 7}
    }
    expect {
      -re {idle .* Enter sends} {}
      timeout {puts "missing idle state"; exit 8}
      eof {puts "early exit before idle state"; exit 9}
    }
    send "\\003"
    expect {
      -exact "\\033\\[?2004l\\033\\[0m\\033\\[?25h\\033\\[?1049l" {}
      -re {BREAK:} {puts "Erlang break menu opened"; exit 10}
      timeout {puts "missing Ctrl+C terminal cleanup"; exit 11}
      eof {puts "early exit before Ctrl+C terminal cleanup"; exit 12}
    }
    expect eof
    puts "probe=passed"
    """

    {output, status} =
      System.cmd(
        "/usr/bin/env",
        isolated_command(
          "/usr/bin/expect",
          ["-c", success_script],
          %{
            "JIDO_BIN" => bin,
            "JIDO_RELEASE_TUI_PROBE" => "success",
            "JIDO_RELEASE_TUI_PROBE_DELAY_MS" => "1000",
            "JIDO_RELEASE_TUI_PROBE_LOG" => log
          }
        ),
        cd: bin |> Path.dirname() |> Path.dirname(),
        stderr_to_stdout: true
      )

    if status != 0 or not String.contains?(output, "probe=passed"),
      do: raise("queued prompt probe failed: #{output}")

    turns = log |> File.read!() |> String.split("\n", trim: true)
    if length(turns) != 1, do: raise("queued prompt ran #{length(turns)} times")

    failure_script = """
    set timeout 12
    log_user 0
    spawn -noecho $env(JIDO_BIN)
    expect {
      -re {Jido} {}
      timeout {puts "missing failure first frame"; exit 2}
      eof {puts "early failure exit"; exit 3}
    }
    expect {
      -re {startup failed .* Esc exits} {}
      timeout {puts "missing startup failure"; exit 4}
      eof {puts "early exit before startup failure"; exit 5}
    }
    send "\\033"
    expect eof
    puts "failure=passed"
    """

    {failure_output, failure_status} =
      System.cmd(
        "/usr/bin/env",
        isolated_command(
          "/usr/bin/expect",
          ["-c", failure_script],
          %{
            "JIDO_BIN" => bin,
            "JIDO_RELEASE_TUI_PROBE" => "failure",
            "JIDO_RELEASE_TUI_PROBE_DELAY_MS" => "300"
          }
        ),
        cd: bin |> Path.dirname() |> Path.dirname(),
        stderr_to_stdout: true
      )

    if failure_status != 0 or not String.contains?(failure_output, "failure=passed"),
      do: raise("startup failure probe failed: #{failure_output}")

    %{
      "first_paint_before_ready" => true,
      "input_during_startup" => true,
      "queued_submission_count" => 1,
      "startup_failure_display" => true,
      "ctrl_c_clean_exit" => true,
      "erlang_break_menu" => false,
      "terminal_cleanup" => true,
      "pseudo_terminal_only" => true
    }
  end

  defp read_only_evidence!(root, bin, version) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort_by(&(-length(Path.split(&1))))
    |> Enum.each(fn path ->
      mode = if File.dir?(path) or executable?(path), do: 0o555, else: 0o444
      File.chmod!(path, mode)
    end)

    File.chmod!(root, 0o555)
    {output, status} = run_command(bin, ["--version"])

    if status != 0 or not String.contains?(output, "jido #{version}"),
      do: raise("read-only package did not run: #{output}")

    %{"passed" => true, "package_writable" => false}
  end

  defp coding_workflow_evidence!(package_root, bin, isolation) do
    workspace = Path.join(isolation, "external-writable-workspace")
    expected = Path.join(isolation, "expected-rate-limiter.ex")
    log = Path.join(isolation, "coding-workflow.jsonl")
    trap_dir = Path.join(isolation, "blocked-system-runtime")
    trap_log = Path.join(isolation, "blocked-system-runtime.log")
    fixture = Oracle.materialize!(workspace)
    prompts = Enum.map(fixture.scenario["turns"], & &1["prompt"])

    File.write!(expected, Oracle.expected_content!("lib/rate_limiter.ex"))
    install_runtime_traps!(trap_dir)

    script = """
    encoding system utf-8
    set timeout 45
    set stty_init "rows 30 columns 100"
    log_user 0
    spawn -noecho $env(JIDO_BIN)
    expect {
      -re {idle .* Enter sends} {}
      timeout {puts "missing initial idle frame"; exit 2}
      eof {puts "early executable exit"; exit 3}
    }
    send "\\033\\[200~$env(JIDO_PROBE_PROMPT_1)\\033\\[201~\\r"
    expect {
      -re {Inspected café λ source and tests\\.} {}
      timeout {puts "missing inspection result"; exit 4}
    }
    send "\\033\\[200~$env(JIDO_PROBE_PROMPT_2)\\033\\[201~\\r"
    expect {
      -re {Review required} {}
      timeout {puts "missing approval review"; exit 5}
    }
    send "a"
    expect {
      -re {Implemented café λ rate limiter\\.} {}
      timeout {puts "missing approved result"; exit 6}
    }
    send "\\033\\[200~$env(JIDO_PROBE_PROMPT_3)\\033\\[201~\\r"
    expect {
      -re {Verification passed\\. Repository review is ready\\.} {}
      -re {error .*} {puts "verification failed: $expect_out(0,string)"; exit 7}
      timeout {puts "missing verification result: $expect_out(buffer)"; exit 7}
    }
    expect {
      -re {Git diff} {}
      timeout {puts "missing Git review"; exit 8}
    }
    expect {
      -re {idle .* Enter sends} {}
      timeout {puts "missing idle state after verification"; exit 9}
    }
    send "\\033"
    expect {
      -exact "\\033\\[?2004l\\033\\[0m\\033\\[?25h\\033\\[?1049l" {}
      timeout {puts "missing terminal cleanup"; exit 10}
    }
    expect eof
    set wait_result [wait]
    if {[llength $wait_result] != 4 || [lindex $wait_result 2] != 0 || [lindex $wait_result 3] != 0} {
      puts "executable failed: $wait_result"
      exit 11
    }
    puts "workflow=passed"
    """

    {output, status} =
      System.cmd(
        "/usr/bin/env",
        isolated_command(
          "/usr/bin/expect",
          ["-c", script],
          %{
            "JIDO_BIN" => bin,
            "JIDO_RELEASE_TUI_PROBE" => "workflow",
            "JIDO_RELEASE_TUI_PROBE_DELAY_MS" => "25",
            "JIDO_RELEASE_TUI_PROBE_WORKSPACE" => workspace,
            "JIDO_RELEASE_TUI_PROBE_EXPECTED" => expected,
            "JIDO_RELEASE_TUI_PROBE_LOG" => log,
            "JIDO_RELEASE_TUI_PROBE_VERIFIER" => "private_runtime",
            "JIDO_PROBE_PROMPT_1" => Enum.at(prompts, 0),
            "JIDO_PROBE_PROMPT_2" => Enum.at(prompts, 1),
            "JIDO_PROBE_PROMPT_3" => Enum.at(prompts, 2),
            "JIDO_RUNTIME_TRAP_LOG" => trap_log,
            "PATH" => trap_dir <> ":/usr/bin:/bin"
          }
        ),
        cd: workspace,
        stderr_to_stdout: true
      )

    if status != 0 or not String.contains?(output, "workflow=passed") do
      raise "packaged coding workflow failed with status #{status}: #{output}"
    end

    if File.exists?(trap_log) do
      raise "packaged coding workflow invoked a blocked system runtime: #{File.read!(trap_log)}"
    end

    records = read_jsonl!(log)
    operations = records |> Enum.filter(&(&1["event"] == "operation")) |> Enum.map(& &1["operation"])

    verification_record =
      Enum.find(records, &(&1["event"] == "verification")) ||
        raise "packaged coding workflow did not record verification"

    verification = Map.drop(verification_record, ["event"])

    unless records |> Enum.filter(&(&1["event"] == "turn_started")) |> length() == 3,
      do: raise("packaged coding workflow did not run exactly three turns")

    unless Enum.any?(records, &(&1 == %{"event" => "review", "decision" => "approved"})),
      do: raise("packaged coding workflow did not approve the edit")

    unless List.last(records) == %{"event" => "session_closed"},
      do: raise("packaged coding workflow did not close its session")

    {:ok, oracle} =
      Oracle.verify_observed(
        fixture,
        operations,
        Oracle.expected_claims(fixture),
        verification
      )

    writable_package_paths = writable_paths(package_root)

    if writable_package_paths != [],
      do: raise("packaged coding workflow changed package permissions: #{inspect(writable_package_paths)}")

    unless writable?(workspace), do: raise("external coding workspace is not writable")

    if String.starts_with?(workspace, package_root <> "/"),
      do: raise("coding workspace is inside the read-only package")

    %{
      "passed" => true,
      "provider_calls" => false,
      "workspace_writable" => writable?(workspace),
      "workspace_outside_package" => not String.starts_with?(workspace, package_root <> "/"),
      "package_writable" => false,
      "system_toolchain" => %{"blocked" => ["erl", "elixir", "mix"], "invocations" => []},
      "verification" => verification,
      "repository_oracle" => "passed",
      "changed_paths" => oracle["changed_paths"],
      "before_digest" => oracle["before_digest"],
      "after_digest" => oracle["after_digest"]
    }
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp install_runtime_traps!(directory) do
    File.mkdir_p!(directory)

    Enum.each(["erl", "elixir", "mix"], fn name ->
      path = Path.join(directory, name)

      File.write!(
        path,
        "#!/bin/sh\nprintf '%s\\n' '#{name}' >> \"$JIDO_RUNTIME_TRAP_LOG\"\nexit 97\n"
      )

      File.chmod!(path, 0o755)
    end)
  end

  defp writable?(path), do: Bitwise.band(File.stat!(path).mode, 0o222) != 0

  defp writable_paths(root) do
    [root | Path.wildcard(Path.join(root, "**/*"), match_dot: true)]
    |> Enum.filter(&writable?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp command_samples(bin, args, count) do
    Enum.map(1..count, fn _index ->
      started = System.monotonic_time()
      {_output, 0} = run_command(bin, args)
      (System.monotonic_time() - started) |> System.convert_time_unit(:native, :microsecond) |> Kernel./(1_000)
    end)
  end

  defp tui_samples(bin, count) do
    script = """
    set timeout 12
    log_user 0
    for {set index 0} {$index < $env(JIDO_SAMPLE_COUNT)} {incr index} {
      spawn -noecho $env(JIDO_BIN)
      set start [clock milliseconds]
      expect {
        -re {Jido} {}
        timeout {puts "missing timing first frame"; exit 2}
        eof {puts "early timing exit"; exit 3}
      }
      set first [expr {[clock milliseconds] - $start}]
      expect {
        -re {idle .* Enter sends} {}
        timeout {puts "missing timing ready state"; exit 4}
        eof {puts "early timing exit before ready"; exit 5}
      }
      set ready [expr {[clock milliseconds] - $start}]
      send "\\033"
      expect eof
      puts "sample=$first,$ready"
    }
    """

    {output, status} =
      System.cmd(
        "/usr/bin/env",
        isolated_command(
          "/usr/bin/expect",
          ["-c", script],
          %{"JIDO_BIN" => bin, "JIDO_SAMPLE_COUNT" => Integer.to_string(count)}
        ),
        cd: bin |> Path.dirname() |> Path.dirname(),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("TUI timing command failed: #{output}")

    samples =
      Regex.scan(~r/sample=(\d+),(\d+)/, output)
      |> Enum.map(fn [_all, first, ready] -> {String.to_integer(first) / 1, String.to_integer(ready) / 1} end)

    if length(samples) != count do
      raise "TUI timing returned #{length(samples)} of #{count} samples: #{inspect(output)}"
    end

    Enum.unzip(samples)
  end

  defp extract_archive!(archive, isolation, version, target) do
    root_name = Contract.root_name(version, target)

    entries =
      case :erl_tar.table(String.to_charlist(archive), [:compressed]) do
        {:ok, names} -> Enum.map(names, &List.to_string/1)
        {:error, reason} -> raise "cannot inspect archive: #{inspect(reason)}"
      end

    unless entries != [] and Enum.all?(entries, &safe_archive_entry?(&1, root_name)) do
      raise "archive has an unsafe or ambiguous entry"
    end

    File.cd!(isolation, fn ->
      case :erl_tar.extract(String.to_charlist(archive), [:compressed]) do
        :ok -> :ok
        {:error, reason} -> raise "cannot extract archive: #{inspect(reason)}"
      end
    end)

    root = Path.join(isolation, root_name)
    if File.dir?(root), do: root, else: raise("archive root is missing")
  end

  defp validate_file_inventory!(root, metadata) do
    expected = Map.new(metadata["files"], &{&1["path"], &1})
    actual = Map.new(Artifact.file_inventory(root), &{&1["path"], &1})

    if expected != actual do
      raise "package file inventory changed: added=#{inspect(Map.keys(actual) -- Map.keys(expected))} " <>
              "removed=#{inspect(Map.keys(expected) -- Map.keys(actual))}"
    end
  end

  defp validate_private_runtime!(root, metadata) do
    launcher = File.read!(Path.join(root, "bin/jido"))
    if String.contains?(launcher, " eval "), do: raise("public launcher contains eval")

    unless String.contains?(launcher, "RELEASE_ROOT") and
             String.contains?(launcher, "erts-$ERTS_VSN/bin/erl") do
      raise "launcher does not select private ERTS"
    end

    Enum.each(metadata["runtime_data"], fn path ->
      unless File.dir?(Path.join(root, path)), do: raise("runtime data is missing: #{path}")
    end)

    native = metadata["native_files"]
    if native == [], do: raise("native library inventory is empty")

    Enum.each(native, fn path ->
      absolute = Path.join(root, path)
      unless File.regular?(absolute), do: raise("native file is missing: #{path}")
      {description, status} = System.cmd("/usr/bin/file", [absolute], stderr_to_stdout: true)

      if status != 0 or not String.contains?(description, "Mach-O") or
           not String.contains?(description, "arm64") do
        raise "native file has the wrong target: #{path}: #{description}"
      end
    end)
  end

  defp validate_evidence!(archive, metadata, expected_sha256) do
    directory = Path.dirname(archive)

    for name <- ["checksums.txt", "release.json", "sbom.json", "provenance.json"] do
      unless File.regular?(Path.join(directory, name)), do: raise("external evidence is missing: #{name}")
    end

    if metadata["components"] == [], do: raise("component inventory is empty")

    checksum = File.read!(Path.join(directory, "checksums.txt"))
    expected_line = "#{expected_sha256}  #{Path.basename(archive)}\n"
    if checksum != expected_line, do: raise("external checksum file is stale or malformed")

    public_text =
      ["release.json", "sbom.json", "provenance.json"]
      |> Enum.map_join("\n", &File.read!(Path.join(directory, &1)))

    home = System.user_home!()
    if String.contains?(public_text, home), do: raise("public evidence contains a private host path")
  end

  defp run_command(bin, args, extra_env \\ %{}) do
    package_root = bin |> Path.dirname() |> Path.dirname()

    System.cmd("/usr/bin/env", isolated_command(bin, args, extra_env),
      cd: package_root,
      stderr_to_stdout: true
    )
  end

  defp isolated_command(command, args, extra_env) do
    environment =
      %{
        "PATH" => "/usr/bin:/bin",
        "LANG" => "C.UTF-8",
        "LC_ALL" => "C.UTF-8",
        "TERM" => "xterm-256color"
      }
      |> Map.merge(extra_env)
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)

    ["-i" | environment] ++ [command | args]
  end

  defp gate!(name, function) do
    IO.puts("release acceptance: #{name}")
    result = function.()
    IO.puts("release acceptance: #{name} passed")
    result
  rescue
    exception ->
      reraise RuntimeError.exception(
                "release acceptance gate #{inspect(name)} failed: #{Exception.message(exception)}"
              ),
              __STACKTRACE__
  end

  defp safe_archive_entry?(entry, root_name) do
    Path.type(entry) == :relative and
      not Enum.member?(Path.split(entry), "..") and
      (entry == root_name or String.starts_with?(entry, root_name <> "/"))
  end

  defp executable?(path), do: Bitwise.band(File.stat!(path).mode, 0o111) != 0

  defp make_writable(root) do
    if File.exists?(root) do
      File.chmod(root, 0o755)

      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.each(&File.chmod(&1, if(File.dir?(&1), do: 0o755, else: 0o644)))
    end
  end

  defp write_json!(path, value) do
    json = Jason.encode_to_iodata!(value, pretty: true) |> IO.iodata_to_binary()
    File.write!(path, json <> "\n")
  end

  defp round_ms(value), do: Float.round(value / 1, 3)
end
