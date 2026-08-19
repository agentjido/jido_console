defmodule Mix.Tasks.Jido.Check do
  @moduledoc "Runs the complete source gate and production escript smoke test."

  use Mix.Task

  alias Jido.Console.Release.Local

  @shortdoc "Validate source and build the developer escript"

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("usage: mix jido.check")

    root = File.cwd!()
    Local.source_gates!(root)
    run!("mix", ["docs"], root, [])
    run!("mix", ["escript.build"], root, [{"MIX_ENV", "prod"}])

    executable = Path.join(root, "jido")
    expect!(executable, ["--version"], "jido #{Jido.Console.version()}", root)
    expect!(executable, ["--help"], "Usage:", root)

    Mix.shell().info("Jido source checks and production escript smoke tests passed.")
  end

  defp expect!(command, args, expected, directory) do
    case System.cmd(command, args, cd: directory, stderr_to_stdout: true) do
      {output, 0} ->
        unless String.contains?(output, expected) do
          Mix.raise("#{Path.basename(command)} #{Enum.join(args, " ")} did not contain #{inspect(expected)}")
        end

      {output, status} ->
        Mix.raise("#{Path.basename(command)} #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  defp run!(command, args, directory, env) do
    case System.cmd(command, args,
           cd: directory,
           env: env,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("#{command} #{Enum.join(args, " ")} failed with status #{status}")
    end
  end
end
