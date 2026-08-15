defmodule Jido.Console.Coding.PathsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Paths
  alias Jido.Console.Release.Boundaries

  @canary "jido-controlled-boundary-canary\n"

  setup do
    root = Path.join(System.tmp_dir!(), "jido-paths-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    artifacts = Path.join(root, "artifacts")
    outside = Path.join(root, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(artifacts)
    File.mkdir_p!(outside)
    File.write!(Path.join(workspace, "ok.txt"), "inside")
    File.write!(Path.join(outside, "canary.txt"), @canary)
    File.ln_s!(Path.join(outside, "canary.txt"), Path.join(workspace, "canary-link.txt"))
    File.ln_s!(outside, Path.join(workspace, "outside-link"))
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      roots: [workspace, artifacts],
      workspace: workspace,
      outside: outside
    }
  end

  test "allows declared roots and denies escape, including normalized paths", %{
    roots: roots,
    workspace: workspace,
    outside: outside
  } do
    assert {:ok, %{outcome: :allow}} = Paths.check(Path.join(workspace, "ok.txt"), roots)
    assert {:ok, %{outcome: :allow}} = Paths.check(artifacts_path(workspace), roots)

    assert {:ok, %{outcome: :deny, reason: reason}} =
             Paths.check(Path.join(outside, "canary.txt"), roots)

    refute reason =~ @canary

    escaped = Path.join(workspace, "../outside/canary.txt")
    assert {:ok, %{outcome: :deny}} = Paths.check(escaped, roots)
  end

  test "rejects file and directory symbolic-link escapes without disclosing the canary", %{
    roots: roots,
    workspace: workspace
  } do
    assert {:ok, %{outcome: :deny}} = Paths.check(Path.join(workspace, "canary-link.txt"), roots)
    assert {:ok, %{outcome: :deny}} = Paths.check(Path.join(workspace, "outside-link/canary.txt"), roots)

    {:ok, decision} = Paths.check(Path.join(workspace, "canary-link.txt"), roots)
    refute inspect(decision) =~ String.trim(@canary)
  end

  test "Gate 0 hostile file-boundary fixtures still pass" do
    result = Boundaries.file_boundary!()
    assert result["status"] == "passed"
    assert Enum.all?(result["cases"], &(&1["classification"] == "denied"))
    refute inspect(result) =~ String.trim(@canary)
  end

  defp artifacts_path(workspace), do: Path.join(Path.dirname(workspace), "artifacts")
end
