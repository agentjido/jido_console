defmodule Jido.Cli.Tui.ViewTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.{EventProjection, State, Turn, View}
  alias Jidoka.Event

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

  test "renders runtime startup, queued prompt, and startup failure states" do
    starting = State.new(nil, {60, 8}, runtime_status: :starting)
    text = starting |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "starting runtime · Enter queues"

    queued = %{starting | submit_when_ready?: true}
    text = queued |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "starting runtime · prompt queued"

    failed = %{starting | runtime_status: :failed, error: "provider failed"}
    text = failed |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "startup failed · Esc exits"
    assert text =~ "provider failed"
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

  test "renders live tool states and safe approval controls" do
    turn = Turn.new(0, "run tools") |> Turn.put_request(%{request_id: "request-1"})

    events = [
      tool_event(:effect_planned, 0, "planned", "read_file"),
      tool_event(:capability_call_started, 1, "running", "search"),
      tool_event(:capability_call_completed, 2, "completed", "git_diff"),
      tool_event(:effect_failed, 3, "failed", "shell", error: "boom"),
      tool_event(:effect_replayed, 4, "retried", "write_file")
    ]

    turn =
      Enum.reduce(events, turn, fn event, turn ->
        {:ok, projection} = EventProjection.project(event)
        {:ok, turn} = Turn.apply_event(turn, projection)
        turn
      end)

    review = %{
      interrupt_id: "review-1",
      operation: "write_file",
      arguments: %{"path" => "\e[31mlib/value.ex\e[0m"},
      reason: :manual
    }

    turn = Turn.put_reviews(turn, [review])
    state = %{State.new(:session, {80, 30}) | active_turn: turn, status: :review}
    text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")

    for marker <- ["[planned]", "[running]", "[done]", "[failed]", "[retried]"] do
      assert text =~ marker
    end

    assert text =~ "Review required"
    assert text =~ "write_file"
    assert text =~ "lib/value.ex"
    assert text =~ "A approve · D deny"
    refute text =~ "\e[31m"
  end

  test "keeps approval decisions in an archived turn" do
    review = %{interrupt_id: "review-1", operation: "shell", arguments: %{"command" => "mix test"}}

    turn =
      Turn.new(0, "test it")
      |> Turn.put_request(%{request_id: "request-1"})
      |> Turn.put_reviews([review])
      |> Turn.decide_review(review, :approve)
      |> Turn.finish(:completed, "done")

    state = %{State.new(:session, {60, 16}) | turns: [turn]}
    text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")

    assert text =~ "[approved] shell"
    assert text =~ "mix test"
    assert text =~ "done"
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

  defp tool_event(event, seq, effect_id, operation, attrs \\ []) do
    Event.build(
      event,
      [],
      Keyword.merge(
        [
          request_id: "request-1",
          seq: seq,
          effect_id: effect_id,
          effect_kind: :operation,
          operation: operation
        ],
        attrs
      )
    )
  end
end
