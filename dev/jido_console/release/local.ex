defmodule Jido.Console.Release.Local do
  @moduledoc "Runs the complete local macOS ARM64 release candidate flow."

  alias Jido.Console.Release.{Acceptance, Artifact, CrossRepo}

  @output_names ~w(
    acceptance.json
    checksums.txt
    manual-tui.json
    provenance.json
    release.json
    sbom.json
  )

  @doc "Runs source gates, builds the archive, accepts it, and atomically promotes dist/."
  @spec run!(keyword()) :: map()
  def run!(opts \\ []) do
    project_root = Keyword.get(opts, :project_root, File.cwd!()) |> Path.expand()
    source = source_identity!(project_root)
    validate_source!(source, Keyword.get(opts, :allow_dirty, false))
    warm_runs = Keyword.get(opts, :warm_runs, 20)
    stage = Path.join(project_root, "_build/jido-release-stage-#{System.unique_integer([:positive])}")
    candidate = Path.join(stage, "candidate")

    File.mkdir_p!(candidate)

    try do
      if Keyword.get(opts, :quality, true), do: source_gates!(project_root)

      artifact =
        Artifact.build!(candidate,
          project_root: project_root,
          source: source,
          build_release: true
        )

      acceptance =
        Acceptance.run!(artifact.archive,
          version: artifact.version,
          target: artifact.target,
          sha256: artifact.archive_sha256,
          warm_runs: warm_runs,
          output: Path.join(candidate, "acceptance.json")
        )

      write_manual_checklist!(candidate, artifact)
      dist = promote!(candidate, artifact, project_root)

      %{
        artifact: Path.join(dist, Path.basename(artifact.archive)),
        acceptance: Path.join(dist, "acceptance.json"),
        dist: dist,
        version: artifact.version,
        target: artifact.target,
        sha256: artifact.archive_sha256,
        metadata: artifact.metadata,
        automated_status: acceptance["status"]
      }
    after
      File.rm_rf!(stage)
    end
  end

  @doc false
  @spec validate_source!(map(), boolean()) :: :ok
  def validate_source!(%{dirty: true}, false) do
    raise "release worktree is dirty; commit the intended source or use --allow-dirty for a non-publishable candidate"
  end

  def validate_source!(%{dirty: dirty}, _allow_dirty) when is_boolean(dirty), do: :ok
  def validate_source!(source, _allow_dirty), do: raise("invalid source identity: #{inspect(source)}")

  @doc false
  @spec source_gates!(Path.t(), keyword()) :: :ok
  def source_gates!(project_root, opts \\ []) do
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    cross_repo_runner = Keyword.get(opts, :cross_repo_runner, &CrossRepo.run!/1)

    gates = [
      {"locked dependencies", "mix", ["deps.get", "--check-locked"], []},
      {"precommit", "mix", ["precommit"], []},
      {"coverage", "mix", ["coveralls"], [{"MIX_ENV", "test"}]}
    ]

    Enum.each(gates, fn {name, command, args, env} ->
      IO.puts("release source gate: #{name}")
      run!(command_runner, command, args, project_root, env)
    end)

    IO.puts("release source gate: cross-repository Jidoka compatibility")
    _evidence = cross_repo_runner.(project_root)
    IO.puts("release source gate: cross-repository Jidoka compatibility passed")
  end

  defp promote!(candidate, artifact, project_root) do
    dist = Path.join(project_root, "dist")
    promotion = Path.join(project_root, "_build/dist-next-#{System.unique_integer([:positive])}")
    backup = Path.join(project_root, "_build/dist-backup-#{System.unique_integer([:positive])}")
    archive_name = Path.basename(artifact.archive)
    output_names = [archive_name | @output_names]

    File.mkdir_p!(promotion)

    Enum.each(output_names, fn name ->
      source = Path.join(candidate, name)
      unless File.regular?(source), do: raise("release output is missing before promotion: #{name}")
      File.cp!(source, Path.join(promotion, name))
    end)

    if File.exists?(dist), do: File.rename!(dist, backup)

    case File.rename(promotion, dist) do
      :ok ->
        File.rm_rf!(backup)
        dist

      {:error, reason} ->
        if File.exists?(backup), do: File.rename!(backup, dist)
        raise "cannot promote local release output: #{inspect(reason)}"
    end
  end

  defp write_manual_checklist!(candidate, artifact) do
    value = %{
      "schema" => "jido.manual-tui",
      "schema_version" => 1,
      "status" => "pending",
      "artifact" => Path.basename(artifact.archive),
      "sha256" => artifact.archive_sha256,
      "version" => artifact.version,
      "target" => artifact.target,
      "checks" => [
        "first paint and runtime ready",
        "input and one queued submission during startup",
        "startup failure text and clean exit",
        "raw input and normal terminal cleanup",
        "cursor and alternate-screen restoration",
        "terminal resize",
        "arrow keys and control keys",
        "bracketed paste",
        "Unicode width and non-ASCII input",
        "Braille display and fallback",
        "ANSI 16-color, 256-color, and true-color modes",
        "abnormal process termination"
      ],
      "results" => []
    }

    json = Jason.encode_to_iodata!(value, pretty: true) |> IO.iodata_to_binary()
    File.write!(Path.join(candidate, "manual-tui.json"), json <> "\n")
  end

  defp source_identity!(project_root) do
    commit = run_capture!("git", ["rev-parse", "HEAD"], project_root) |> String.trim()
    dirty = run_capture!("git", ["status", "--porcelain", "--untracked-files=normal"], project_root) != ""
    %{commit: commit, dirty: dirty}
  end

  defp run!(runner, command, args, directory, env) do
    case runner.(command, args,
           cd: directory,
           env: env,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_output, 0} -> ""
      {_output, status} -> raise "release command #{command} failed with status #{status}"
    end
  end

  defp run_capture!(command, args, directory) do
    case System.cmd(command, args, cd: directory, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "release command #{command} failed with status #{status}: #{output}"
    end
  end
end
