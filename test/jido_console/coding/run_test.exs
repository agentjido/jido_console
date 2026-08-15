defmodule Jido.Console.Coding.RunTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.{Approval, Run}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "keep.txt"), "keep")
    File.write!(Path.join(root, "edit.txt"), "before")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "binds context to the opened run id and snapshots hidden files", %{root: root} do
    File.write!(Path.join(root, ".gitignore"), "ignore-me")
    assert {:ok, run} = Run.open(root)
    assert run.context.run_id == run.id
    assert run.id != "run"
    assert Run.manifest(run)["files"][".gitignore"] != nil
  end

  test "reviews proposed effects and rejects without changing the workspace", %{root: root} do
    assert {:ok, run} = Run.open(root, run_id: "run-1")
    assert Run.manifest(run)["files"]["edit.txt"] != nil

    effect = %{operation: "coding.edit", path: "edit.txt", params: %{old_text: "before", new_text: "after"}}
    assert {:ok, transcript} = Run.review([effect])
    assert transcript =~ "effect: coding.edit edit.txt"
    assert transcript =~ "new_text: \"after\""

    assert {:ok, run} = Run.reject(run, effect)
    assert File.read!(Path.join(root, "edit.txt")) == "before"
    assert run.rejected != []
    assert hd(run.rejected).path == "edit.txt"
  end

  test "applies an approved effect and reverts only the current run", %{root: root} do
    assert {:ok, run} = Run.open(root, run_id: "run-1")
    effect = %{operation: "coding.edit", path: "edit.txt", params: %{new_text: "after"}}
    assert {:ok, binding} = Approval.bind(effect, run.context)
    assert {:ok, run, diff} = Run.apply_effect(run, effect, binding)
    assert File.read!(Path.join(root, "edit.txt")) == "after"
    assert diff.after != diff.before

    File.write!(Path.join(root, "keep.txt"), "unrelated after start")
    File.write!(Path.join(root, "outside.txt"), "created outside the run")

    assert {:ok, reverted} = Run.revert(run)
    assert File.read!(Path.join(root, "edit.txt")) == "before"
    assert File.read!(Path.join(root, "keep.txt")) == "unrelated after start"
    assert File.read!(Path.join(root, "outside.txt")) == "created outside the run"
    assert reverted.status == :reverted
    assert {:error, :run_already_reverted} = Run.revert(reverted)
  end

  test "a path or approval mismatch is not applied", %{root: root} do
    assert {:ok, run} = Run.open(root, run_id: "run-1")
    effect = %{operation: "coding.edit", path: "../secret.txt", params: %{new_text: "nope"}}
    assert {:ok, binding} = Approval.bind(effect, run.context)
    assert {:error, :path_boundary_denied} = Run.apply_effect(run, effect, binding)
    refute File.exists?(Path.join(Path.dirname(root), "secret.txt"))

    safe = %{operation: "coding.edit", path: "edit.txt", params: %{new_text: "after"}}
    assert {:ok, other} = Approval.bind(safe, %{run.context | run_id: "run-2"})
    assert {:error, :approval_mismatch} = Run.apply_effect(run, safe, other)
    assert File.read!(Path.join(root, "edit.txt")) == "before"
  end

  test "an incomplete revert is a failure and does not claim a clean workspace", %{root: root} do
    assert {:ok, run} = Run.open(root, run_id: "run-1")
    effect = %{operation: "coding.edit", path: "edit.txt", params: %{new_text: "after"}}
    assert {:ok, binding} = Approval.bind(effect, run.context)
    assert {:ok, run, _diff} = Run.apply_effect(run, effect, binding)

    writer = fn _path, _content -> {:error, :eacces} end
    assert {:error, {:incomplete_revert, failed, [{"edit.txt", :eacces}]}} = Run.revert(run, write: writer)
    assert failed.status == :failed
    assert File.read!(Path.join(root, "edit.txt")) == "after"
  end
end
