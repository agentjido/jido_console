defmodule Jido.Cli.Tui.ViewTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.State
  alias Jido.Cli.Tui.View

  test "renders a useful warning when the terminal is too small" do
    frame = State.new(:session, {10, 4}) |> View.render()
    assert Enum.join(frame.rows, "\n") =~ "Terminal i"
    assert frame.cursor == nil
  end

  test "renders streaming content as a temporary assistant message" do
    state = %{
      State.new(:session, {40, 10})
      | messages: [%{role: :user, content: "hello"}],
        streaming: "working",
        status: :running
    }

    text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "User"
    assert text =~ "Assistant"
    assert text =~ "working"
    assert text =~ "running · Ctrl-C cancels"
  end

  test "renders each terminal status" do
    cases = [
      {:cancelling, nil, "cancelling"},
      {:interrupted, nil, "paused"},
      {:interrupted, "review needed", "review needed"},
      {:error, "failed", "error · failed"},
      {:custom, nil, "custom"}
    ]

    for {status, error, expected} <- cases do
      state = %{State.new(:session, {40, 8}) | status: status, error: error}
      text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
      assert text =~ expected
    end
  end

  test "renders edits, checkpoints, structural diffs, and stable status markers" do
    reviews = [
      %{
        "kind" => "edit",
        "path" => "lib/value.ex",
        "operation" => "edit",
        "operation_id" => "edit-1",
        "status" => "changed",
        "before_sha256" => "sha256:111111111111",
        "after_sha256" => "sha256:222222222222",
        "checkpoint_ref" => "checkpoint-1",
        "diff" => %{
          "before_lines" => 4,
          "after_lines" => 5,
          "changed_before_lines" => 1,
          "changed_after_lines" => 2
        },
        "truncated" => false
      },
      %{
        "kind" => "checkpoint",
        "path" => "lib/other.ex",
        "status" => "restored",
        "checkpoint_ref" => "checkpoint-2",
        "message" => "Restore complete.",
        "truncated" => false
      }
    ]

    state = %{State.new(:session, {80, 24}) | coding_reviews: reviews}
    text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "Review"
    assert text =~ "[changed] lib/value.ex"
    assert text =~ "checkpoint checkpoint-1"
    assert text =~ "changed -1 +2"
    assert text =~ "[restored] lib/other.ex"
  end

  test "renders binary and truncated Git review without secret content" do
    review = %{
      "kind" => "git_diff",
      "path" => nil,
      "operation" => "git diff",
      "operation_id" => nil,
      "status" => "changed",
      "files" => [
        %{
          "path" => "[redacted]",
          "binary" => true,
          "additions" => nil,
          "deletions" => nil,
          "redacted" => true
        }
      ],
      "patch" => "[redacted sensitive diff]",
      "binary" => true,
      "truncated" => true,
      "checkpoint_ref" => nil
    }

    state = %{State.new(:session, {50, 14}) | coding_reviews: [review]}
    text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "binary"
    assert text =~ "truncated"
    assert text =~ "[redacted]"
    refute text =~ "TOKEN="
  end

  test "review remains readable in a small supported terminal and truncates rows" do
    reviews =
      Enum.map(1..10, fn index ->
        %{
          "kind" => "mutation_state",
          "path" => "lib/#{index}.ex",
          "status" => "conflict",
          "checkpoint_ref" => nil,
          "truncated" => false
        }
      end)

    frame = View.render(%{State.new(:session, {24, 7}) | coding_reviews: reviews})
    assert length(frame.rows) == 7
    assert Enum.join(frame.rows, "\n") =~ "review truncated"
  end

  test "view source cannot read files, run commands, or modify Git" do
    source = File.read!("lib/jido_cli/cli/tui/view.ex")

    for forbidden <- ["File.", "System.cmd", "Port.open", "git commit", "git add", "git checkout"] do
      refute source =~ forbidden
    end
  end
end
