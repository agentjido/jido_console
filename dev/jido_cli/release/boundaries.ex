defmodule Jido.Cli.Release.Boundaries do
  @moduledoc "Runs controlled file and runtime boundary probes for release preparation."

  alias Jidoka.CodingPack.{Error, Read, Workspace}

  @canary "jido-controlled-boundary-canary\n"

  @doc false
  @spec file_boundary!(keyword()) :: map()
  def file_boundary!(opts \\ []) do
    probe = Keyword.get(opts, :probe, &Read.run/2)
    runs = Enum.map(1..2, fn _index -> file_run!(probe) end)

    unless Enum.at(runs, 0) == Enum.at(runs, 1) do
      raise "file-boundary probes are not repeatable"
    end

    %{
      "status" => "passed",
      "canary_sha256" => digest(@canary),
      "cases" => hd(runs),
      "repeat_runs" => 2,
      "risk_control" => "jido_console-m1e15"
    }
  end

  defp file_run!(probe) do
    fixture = file_fixture!()

    try do
      workspace = Workspace.new!(root: fixture.workspace, access: [:read])

      [
        {"parent_traversal", "../outside/canary.txt"},
        {"absolute_path", fixture.canary},
        {"file_symlink", "canary-link.txt"},
        {"directory_symlink", "outside-link/canary.txt"}
      ]
      |> Enum.map(fn {name, path} ->
        classification = classify_file_result(probe.(workspace, %{"path" => path}))

        if classification != "denied" do
          raise "file-boundary case #{name} expected denied but got #{classification}"
        end

        %{"name" => name, "classification" => classification}
      end)
    after
      File.rm_rf!(fixture.root)
    end
  end

  defp file_fixture! do
    root = temporary_path("jido-file-boundary")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    canary = Path.join(outside, "canary.txt")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.write!(canary, @canary)
    File.ln_s!(canary, Path.join(workspace, "canary-link.txt"))
    File.ln_s!(outside, Path.join(workspace, "outside-link"))
    %{root: root, workspace: workspace, canary: canary}
  end

  defp classify_file_result({:error, %Error{code: :workspace_path_rejected}}), do: "denied"
  defp classify_file_result({:ok, _result}), do: "known_risk"
  defp classify_file_result(result), do: raise("unsupported file-boundary result: #{inspect(result)}")

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp temporary_path(prefix) do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "#{prefix}-#{id}")
  end
end
