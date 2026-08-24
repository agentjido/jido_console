defmodule Jido.Console.Coding.WorkspaceConfig do
  @moduledoc "Builds the bounded Jidoka workspace for the selected execution policy."

  alias Jido.Console.ExecutionPolicy
  alias Jidoka.CodingPack.Workspace

  @local_limits %{
    max_file_bytes: 262_144,
    max_result_bytes: 262_144,
    max_search_files: 2_000,
    max_search_results: 100,
    max_shell_args: 32,
    max_shell_stdin_bytes: 1,
    max_shell_output_bytes: 262_144,
    max_shell_timeout_ms: 120_000
  }

  @doc "Builds one workspace from trusted host options."
  @spec build(String.t(), keyword()) :: {:ok, Workspace.t()} | {:error, term()}
  def build(execution_policy_id, opts) do
    execution_policy_id = ExecutionPolicy.normalize_id(execution_policy_id)
    root = Keyword.get(opts, :project_root, Application.get_env(:jido_console, :project_root))

    if execution_policy_id == ExecutionPolicy.trusted_id() and is_nil(root) do
      {:error, :local_coding_root_required}
    else
      new_workspace(execution_policy_id, root || File.cwd!(), opts)
    end
  end

  @doc "Returns the relative instruction-discovery directory."
  @spec working_directory(keyword()) :: String.t()
  def working_directory(opts) do
    Keyword.get(
      opts,
      :coding_working_directory,
      Application.get_env(:jido_console, :coding_working_directory, ".")
    )
  end

  defp new_workspace(execution_policy_id, root, opts) do
    Workspace.new(
      root: root,
      access:
        Keyword.get(
          opts,
          :coding_access,
          Application.get_env(:jido_console, :coding_access, [:read, :write, :shell, :git, :verify])
        ),
      limits:
        Keyword.get(
          opts,
          :coding_limits,
          Application.get_env(:jido_console, :coding_limits, @local_limits)
        ),
      execution_profile: execution_policy_id
    )
  end
end
