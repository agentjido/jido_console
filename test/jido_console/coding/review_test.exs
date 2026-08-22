defmodule Jido.Console.Coding.ReviewTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Review
  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Turn

  @digest "sha256:" <> String.duplicate("a", 64)

  test "normalizes one edit without file content" do
    assert [review] = Review.project_candidates([edit("lib/value.ex", "edit-1")])
    assert review["path"] == "lib/value.ex"
    assert review["operation"] == "edit"
    assert review["before_sha256"] == "sha256:aaaaaaaaaaaa"
    assert review["after_sha256"] == "sha256:aaaaaaaaaaaa"
    assert review["checkpoint_ref"] == "checkpoint-1"
    assert review["diff"]["changed_before_lines"] == 1
    refute inspect(review) =~ "secret file content"
  end

  test "sorts multiple edits and supports distinct portable mutation states" do
    states = [
      %{"kind" => "mutation_state", "path" => "lib/z.ex", "status" => "conflict", "operation_id" => "3"},
      %{"kind" => "checkpoint", "path" => "lib/y.ex", "status" => "restored", "checkpoint_ref" => "checkpoint-2"},
      %{"kind" => "mutation_state", "path" => "lib/x.ex", "status" => "interrupted", "operation_id" => "1"},
      edit("lib/a.ex", "2")
    ]

    reviews = Review.project_candidates(states)
    assert Enum.map(reviews, & &1["path"]) == ["lib/a.ex", "lib/x.ex", "lib/y.ex", "lib/z.ex"]
    assert Enum.map(reviews, & &1["status"]) == ["changed", "interrupted", "restored", "conflict"]
  end

  test "normalizes no-change, binary, and truncated Git diffs" do
    assert [%{"status" => "no_change", "files" => []}] =
             Review.project_candidates([%{"kind" => "git_diff", "status" => "ok", "files" => [], "patch" => ""}])

    patch = String.duplicate("x", 9_000)

    assert [review] =
             Review.project_candidates([
               %{
                 "kind" => "git_diff",
                 "status" => "changed",
                 "files" => [%{"path" => "image.bin", "binary" => true}],
                 "patch" => patch
               }
             ])

    assert review["binary"]
    assert review["truncated"]
    assert byte_size(review["patch"]) == 8_192

    assert [%{"status" => "changed"} = changed] =
             Review.project_candidates([
               %{
                 "kind" => "git_diff",
                 "status" => "ok",
                 "files" => [%{"path" => "lib/value.ex", "additions" => 1, "deletions" => 0}],
                 "patch" => "safe\e[31m"
               }
             ])

    refute changed["patch"] =~ "\e"
  end

  test "redacts sensitive paths and rejects malformed or unsafe records" do
    assert [review] = Review.project_candidates([edit("config/.env", "edit-1")])
    assert review["path"] == "[redacted]"
    assert review["diff"] == %{"redacted" => true}

    assert [%{"patch" => "[redacted sensitive diff]"}] =
             Review.project_candidates([
               %{
                 "kind" => "git_diff",
                 "status" => "changed",
                 "files" => [%{"path" => "private.key", "binary" => false}],
                 "patch" => "secret file content"
               }
             ])

    assert Review.project_candidates([
             %{"kind" => "unknown"},
             edit("../outside", "bad"),
             edit("C:\\outside", "bad"),
             edit("lib/unsafe\e[31m.ex", "bad"),
             "bad"
           ]) == []
  end

  test "uses only operation results from the completed turn" do
    old = operation_result("old-request", "lib/old.ex")
    current = operation_result("current-request", "lib/current.ex")

    result =
      Turn.Result.new!(
        content: "done",
        agent_state: Agent.State.new!(operation_results: [old, current]),
        journal: Effect.Journal.new!(),
        metadata: %{debug: %{request_id: "current-request"}}
      )

    {:ok, session} = Jidoka.session(Jido.Console.DefaultAgent)
    session = Session.put_result(session, result)

    assert [candidate] = Review.candidates_from_session(session)
    assert [%{"path" => "lib/current.ex"}] = Review.project_candidates([candidate])
  end

  test "extracts Git review output and ignores unrelated operations" do
    git_diff =
      Effect.OperationResult.new!(
        operation: "coding.git_diff",
        arguments: %{},
        output: %{status: "changed", files: [%{path: "lib/current.ex"}], patch: "diff"},
        request_id: "current-request"
      )

    unrelated =
      Effect.OperationResult.new!(
        operation: "coding.read",
        arguments: %{},
        output: %{"path" => "lib/current.ex"},
        request_id: "current-request"
      )

    result =
      Turn.Result.new!(
        content: "done",
        agent_state: Agent.State.new!(operation_results: [unrelated, git_diff]),
        journal: Effect.Journal.new!(),
        metadata: %{"debug" => %{"request_id" => "current-request"}}
      )

    {:ok, session} = Jidoka.session(Jido.Console.DefaultAgent)
    session = Session.put_result(session, result)

    assert [%{"kind" => "git_diff"} = candidate] = Review.candidates_from_session(session)
    assert [%{"path" => nil, "patch" => "diff"}] = Review.project_candidates([candidate])
    assert Review.candidates_from_session(:invalid) == []
  end

  test "fails closed for malformed review fields" do
    assert Review.project_candidates(:invalid) == []

    assert Review.project_candidates([
             edit(nil, "bad"),
             edit(42, "bad"),
             put_in(edit("lib/value.ex", "bad"), ["after_sha256"], "invalid")
           ]) == []

    malformed_edit =
      edit("lib/value.ex", "bad")
      |> Map.put("action", 42)
      |> Map.put("operation_id", String.duplicate("x", 129))
      |> Map.put("before_sha256", "invalid")
      |> Map.put("diff", :invalid)

    assert [review] = Review.project_candidates([malformed_edit])
    assert review["operation"] == nil
    assert review["operation_id"] == nil
    assert review["before_sha256"] == nil
    assert review["diff"] == %{}

    nil_digest = Map.put(edit("lib/other.ex", "ok"), "before_sha256", nil)
    assert [%{"before_sha256" => nil}] = Review.project_candidates([nil_digest])
  end

  test "normalizes malformed Git diff metadata without exposing raw values" do
    assert [%{"files" => [], "status" => "no_change", "patch" => ""}] =
             Review.project_candidates([
               %{"kind" => "git_diff", "files" => :invalid, "patch" => 42, "status" => "ok"}
             ])

    assert [%{"files" => [file], "patch" => ""}] =
             Review.project_candidates([
               %{
                 "kind" => "git_diff",
                 "files" => [
                   %{"path" => nil},
                   %{"path" => "lib/value.ex", "additions" => -1, "deletions" => "many"}
                 ],
                 "patch" => <<255>>,
                 "status" => "changed"
               }
             ])

    assert file == %{
             "path" => "lib/value.ex",
             "binary" => false,
             "additions" => nil,
             "deletions" => nil,
             "redacted" => false
           }
  end

  test "drops invalid portable mutation metadata" do
    state = %{
      "kind" => "mutation_state",
      "path" => "lib/value.ex",
      "status" => "failed",
      "operation" => 42,
      "operation_id" => String.duplicate("x", 129),
      "message" => String.duplicate("m", 257)
    }

    assert [review] = Review.project_candidates([state])
    assert review["operation"] == nil
    assert review["operation_id"] == nil
    assert review["message"] == nil
  end

  test "caps record count" do
    records = Enum.map(1..60, &edit("lib/#{&1}.ex", Integer.to_string(&1)))
    assert length(Review.project_candidates(records)) == 50
  end

  defp edit(path, operation_id) do
    %{
      "kind" => "edit",
      "path" => path,
      "action" => "edit",
      "operation_id" => operation_id,
      "before_sha256" => @digest,
      "after_sha256" => @digest,
      "checkpoint" => %{"checkpoint_ref" => "checkpoint-1"},
      "diff" => %{
        "before_lines" => 3,
        "after_lines" => 3,
        "changed_before_lines" => 1,
        "changed_after_lines" => 1
      },
      "content" => "secret file content"
    }
  end

  defp operation_result(request_id, path) do
    Effect.OperationResult.new!(
      operation: "coding.edit",
      arguments: %{},
      output: edit(path, request_id) |> Map.delete("kind"),
      request_id: request_id
    )
  end
end
