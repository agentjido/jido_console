defmodule Mix.Tasks.Jido.Release.Audit do
  use Mix.Task

  @shortdoc "Run an opt-in local release-readiness audit"
  @moduledoc """
  Runs release-readiness checks outside the normal development path.

      mix jido.release.audit
      mix jido.release.audit --check workflow-policy
      mix jido.release.audit --check delivery-plan --check delivery-trace
      mix jido.release.audit --output /path/to/local-audit

  The source checkout must be clean. Without `--output`, the task deletes its
  temporary result after the audit. The task does not upload or publish data.
  """

  @impl Mix.Task
  def run(args) do
    {options, remaining, invalid} =
      OptionParser.parse(args,
        strict: [check: :string, output: :string, keep_workspaces: :boolean],
        aliases: []
      )

    if remaining != [] or invalid != [] do
      Mix.raise("usage: mix jido.release.audit [--check NAME] [--output PATH] [--keep-workspaces]")
    end

    checks = Keyword.get_values(options, :check)

    audit_options =
      [keep_workspaces: Keyword.get(options, :keep_workspaces, false)]
      |> put_if_present(:checks, if(checks == [], do: nil, else: checks))
      |> put_if_present(:output, options[:output])

    result = Jido.Cli.Release.Audit.run!(audit_options)

    Mix.shell().info("Release-readiness audit passed.")

    if result["retained"] do
      Mix.shell().info("Local result: #{Path.join(result["output"], "audit.json")}")
    else
      Mix.shell().info("Temporary result removed.")
    end

    Mix.shell().info("Upload: not done; publication: not done")
  end

  defp put_if_present(options, _key, nil), do: options
  defp put_if_present(options, key, value), do: Keyword.put(options, key, value)
end
