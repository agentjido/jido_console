defmodule Jido.Cli.Release.CrossRepo do
  @moduledoc "Runs the local CLI compatibility gate against sibling and pinned Jidoka sources."

  @type evidence :: %{required(String.t()) => boolean() | String.t()}

  @doc "Runs one complete CLI test pass for each required Jidoka source."
  @spec run!(Path.t(), keyword()) :: evidence()
  def run!(project_root, opts \\ []) do
    project_root = Path.expand(project_root)
    sibling = Keyword.get_lazy(opts, :sibling, fn -> default_sibling!(project_root) end)
    pinned_checkout = Keyword.get(opts, :pinned_checkout, Path.join(project_root, "deps/jidoka"))
    pinned_ref = Keyword.get_lazy(opts, :pinned_ref, &pinned_ref!/0)
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    require_git_checkout!(sibling, "sibling Jidoka")
    require_clean!(runner, sibling, "sibling Jidoka")
    sibling_commit = git!(runner, sibling, ["rev-parse", "HEAD"])

    run_mix_gate!(runner, project_root, sibling)

    pinned_env = gate_env(nil)
    run!(runner, "mix", ["deps.get", "--check-locked"], project_root, pinned_env)
    require_git_checkout!(pinned_checkout, "pinned Jidoka dependency")
    require_clean!(runner, pinned_checkout, "pinned Jidoka dependency")
    pinned_commit = git!(runner, pinned_checkout, ["rev-parse", "HEAD"])

    if pinned_commit != pinned_ref do
      raise "Jidoka pin #{pinned_ref} does not name tested dependency commit #{pinned_commit}"
    end

    run!(runner, "mix", ["test", "--seed", "0"], project_root, pinned_env)

    %{
      "pin_names_tested_commit" => true,
      "pinned_commit" => pinned_commit,
      "pinned_source" => "locked Git dependency",
      "sibling_commit" => sibling_commit,
      "sibling_source" => sibling,
      "test_command" => "mix test --seed 0"
    }
  end

  @doc false
  @spec pinned_ref!() :: String.t()
  def pinned_ref! do
    case Mix.Dep.Lock.read()[:jidoka] do
      {:git, "https://github.com/agentjido/jidoka.git", commit, options}
      when is_binary(commit) and byte_size(commit) == 40 ->
        if options[:ref] == commit,
          do: commit,
          else: raise("Jidoka lock ref does not match its locked commit")

      other ->
        raise "Jidoka lock is not one exact agentjido/jidoka Git commit: #{inspect(other)}"
    end
  end

  defp run_mix_gate!(runner, project_root, sibling) do
    env = gate_env(sibling)
    run!(runner, "mix", ["deps.get", "--check-locked"], project_root, env)
    run!(runner, "mix", ["test", "--seed", "0"], project_root, env)
  end

  defp default_sibling!(project_root) do
    case System.cmd("git", ["rev-parse", "--git-common-dir"],
           cd: project_root,
           stderr_to_stdout: true
         ) do
      {common_directory, 0} ->
        common_directory
        |> String.trim()
        |> Path.expand(project_root)
        |> Path.dirname()
        |> Path.join("../jidoka")
        |> Path.expand()

      {output, status} ->
        raise "cannot locate sibling Jidoka checkout from Git metadata (status #{status}): #{output}"
    end
  end

  defp gate_env(sibling) do
    [
      {"JIDO_CLI_JIDOKA_PATH", sibling},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_ENV", "test"}
    ]
  end

  defp require_git_checkout!(path, label) do
    unless File.dir?(path) and File.exists?(Path.join(path, ".git")) do
      raise "#{label} is missing at #{path}"
    end
  end

  defp require_clean!(runner, path, label) do
    if git!(runner, path, ["status", "--porcelain", "--untracked-files=normal"]) != "" do
      raise "#{label} must be clean before its commit can be named as tested"
    end
  end

  defp git!(runner, directory, args) do
    run!(runner, "git", args, directory, []) |> String.trim()
  end

  defp run!(runner, command, args, directory, env) do
    case runner.(command, args, cd: directory, env: env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "#{command} #{Enum.join(args, " ")} failed with status #{status}:\n#{output}"
    end
  end
end
