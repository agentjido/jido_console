defmodule Mix.Tasks.Jido.Scenario.Prepare do
  @moduledoc "Prepares a clean local repository for the live coding scenario."

  use Mix.Task

  @shortdoc "Prepare the isolated live coding scenario"

  @impl true
  def run(args) do
    force? = "--force" in args
    package_root = Path.expand("../../..", __DIR__)
    source = Path.join(package_root, "release/fixtures/coding/rate_limiter")
    target = Path.join(package_root, ".jido/scenarios/rate_limiter")

    with :ok <- prepare_target(target, force?),
         {:ok, _files} <- File.cp_r(source, target),
         :ok <- initialize_repository(target) do
      Mix.shell().info(target)
    else
      {:error, reason} -> Mix.raise("could not prepare coding scenario: #{inspect(reason)}")
    end
  end

  defp prepare_target(target, false) do
    if File.exists?(target), do: {:error, :target_exists_use_force}, else: File.mkdir_p(Path.dirname(target))
  end

  defp prepare_target(target, true) do
    with {:ok, _removed} <- File.rm_rf(target), do: File.mkdir_p(Path.dirname(target))
  end

  defp initialize_repository(target) do
    commands = [
      ["init", "-q"],
      ["config", "user.name", "Jido Scenario"],
      ["config", "user.email", "scenario@example.invalid"],
      ["add", "."],
      ["commit", "-q", "-m", "Initial failing scenario"]
    ]

    Enum.reduce_while(commands, :ok, fn args, :ok ->
      case System.cmd("git", args, cd: target, stderr_to_stdout: true) do
        {_output, 0} -> {:cont, :ok}
        {output, status} -> {:halt, {:error, {:git_failed, args, status, output}}}
      end
    end)
  end
end
