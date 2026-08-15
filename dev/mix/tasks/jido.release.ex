defmodule Mix.Tasks.Jido.Release do
  use Mix.Task

  @shortdoc "Build and accept one local macOS ARM64 release candidate"
  @moduledoc """
  Builds, audits, packages, and tests the exact local release archive.

      mix jido.release
      mix jido.release --allow-dirty

  A dirty override creates an unsigned, non-publishable development candidate.
  The task does not tag, sign, notarize, upload, publish, or change Homebrew.
  """

  @impl Mix.Task
  def run(args) do
    {options, remaining, invalid} =
      OptionParser.parse(args,
        strict: [allow_dirty: :boolean, warm_runs: :integer],
        aliases: []
      )

    if remaining != [] or invalid != [] do
      Mix.raise("usage: mix jido.release [--allow-dirty] [--warm-runs N]")
    end

    warm_runs = Keyword.get(options, :warm_runs, 20)
    if warm_runs < 1, do: Mix.raise("--warm-runs must be at least 1")

    result =
      Jido.Console.Release.Local.run!(
        allow_dirty: Keyword.get(options, :allow_dirty, false),
        warm_runs: warm_runs
      )

    Mix.shell().info("Local Jido release candidate passed automated acceptance.")
    Mix.shell().info("Artifact: #{result.artifact}")
    Mix.shell().info("Version: #{result.homebrew["version"]}")
    Mix.shell().info("Target: #{result.homebrew["target"]}")
    Mix.shell().info("SHA-256: #{result.homebrew["sha256"]}")
    Mix.shell().info("Future Brew executable: #{result.homebrew["executable"]}")
    Mix.shell().info("Manual TUI status: pending in #{Path.join(result.dist, "manual-tui.json")}")
    Mix.shell().info("Signing: not done; notarization: not done; publication: not done; Homebrew: not done")
  end
end
