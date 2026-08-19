defmodule Jido.Console.Release.Acceptance do
  @moduledoc "Validates and benchmarks the exact final release archive."

  alias Jido.Console.Release.{Artifact, Contract, CrossRepo}

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
    runtime_env = acceptance_environment!(isolation)

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

      startup =
        gate!("startup performance", fn -> startup_evidence!(bin, warm_runs, limits, runtime_env) end)

      commands =
        gate!("packaged commands", fn -> command_evidence!(bin, expected_version, runtime_env) end)

      read_only =
        gate!("read-only installation", fn ->
          read_only_evidence!(root, bin, expected_version, runtime_env)
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
        "home" => %{
          "source" => "JIDO_HOME",
          "isolated" => true,
          "operator_home_used" => false
        },
        "isolated_path_features" => ["spaces", "non_ascii"],
        "path" => %{"value" => "/usr/bin:/bin", "erl" => false, "elixir" => false, "mix" => false},
        "live_provider_calls" => false,
        "startup" => startup,
        "commands" => commands,
        "read_only_installation" => read_only,
        "gates" => [
          "archive checksum",
          "metadata contract",
          "internal file inventory",
          "private runtime",
          "notices and evidence",
          "startup performance",
          "packaged commands",
          "read-only installation"
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

  @doc false
  @spec acceptance_environment!(Path.t()) :: %{required(String.t()) => String.t()}
  def acceptance_environment!(isolation) when is_binary(isolation) do
    home = Path.join(isolation, "jido-home")
    File.mkdir_p!(home)
    File.chmod!(home, 0o700)
    %{"JIDO_HOME" => home}
  end

  defp startup_evidence!(bin, warm_runs, limits, runtime_env) when warm_runs > 0 do
    help = command_samples(bin, ["--help"], warm_runs + 1, runtime_env)
    version = command_samples(bin, ["--version"], warm_runs + 1, runtime_env)
    {first_frame, runtime_ready} = tui_samples(bin, warm_runs + 1, runtime_env)

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

  defp command_evidence!(bin, version, runtime_env) do
    checks = [
      {"version", ["--version"], 0, "jido #{version}"},
      {"help", ["--help"], 0, "Usage:"},
      {"execution_error", ["--release-unknown-option"], 1, "unknown option"}
    ]

    Enum.map(checks, fn {name, args, status, text} ->
      {output, actual_status} = run_command(bin, args, runtime_env)

      if actual_status != status, do: raise("#{name} returned #{actual_status}, expected #{status}: #{output}")
      unless String.contains?(output, text), do: raise("#{name} output did not contain #{inspect(text)}")
      %{"name" => name, "status" => status}
    end)
  end

  defp read_only_evidence!(root, bin, version, runtime_env) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort_by(&(-length(Path.split(&1))))
    |> Enum.each(fn path ->
      mode = if File.dir?(path) or executable?(path), do: 0o555, else: 0o444
      File.chmod!(path, mode)
    end)

    File.chmod!(root, 0o555)
    {output, status} = run_command(bin, ["--version"], runtime_env)

    if status != 0 or not String.contains?(output, "jido #{version}"),
      do: raise("read-only package did not run: #{output}")

    %{"passed" => true, "package_writable" => false}
  end

  defp command_samples(bin, args, count, runtime_env) do
    Enum.map(1..count, fn _index ->
      started = System.monotonic_time()
      {_output, 0} = run_command(bin, args, runtime_env)
      (System.monotonic_time() - started) |> System.convert_time_unit(:native, :microsecond) |> Kernel./(1_000)
    end)
  end

  defp tui_samples(bin, count, runtime_env) do
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
          Map.merge(runtime_env, %{"JIDO_BIN" => bin, "JIDO_SAMPLE_COUNT" => Integer.to_string(count)})
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
    expected_line = "#{expected_sha256}  #{Path.basename(archive)}"
    lines = String.split(checksum, "\n", trim: true)
    unless expected_line in lines, do: raise("external checksum file is stale or malformed")

    public_text =
      ["release.json", "sbom.json", "provenance.json"]
      |> Enum.map_join("\n", &File.read!(Path.join(directory, &1)))

    home = System.user_home!()
    if String.contains?(public_text, home), do: raise("public evidence contains a private host path")
  end

  defp run_command(bin, args, extra_env) do
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
