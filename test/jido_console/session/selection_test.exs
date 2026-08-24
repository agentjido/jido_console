defmodule Jido.Console.Session.SelectionTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{BindingManifest, BindingRequest, Command, Selection}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-session-selection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "builds and resumes the exact default draft" do
    assert {:ok, selection} = Selection.new(thread_id: "selection-default")
    assert selection.state == :ready_unlocked
    assert selection.binding.model_id == "openai:gpt-4.1-mini"
    assert selection.binding.model_origin == :agent_spec
    assert selection.binding.execution_policy.execution_policy_id == "coding.restricted"

    assert {:ok, session} = Selection.start_session(selection, "selection-default")
    assert {:ok, resumed} = Selection.resume(session, thread_id: "selection-default")
    assert resumed.state == :ready_unlocked
    assert resumed.manifest == selection.manifest
    assert resumed.binding.bound_spec == selection.binding.bound_spec
  end

  test "requires a direct policy choice for a broader file request", %{root: root} do
    source = Path.expand("test/fixtures/agents/trusted.json")
    assert {:ok, pending} = Selection.new(thread_id: "needs-policy", agent_source: source)
    assert pending.state == :needs_policy

    assert {:ok, selected} =
             Selection.select_execution_policy(
               pending,
               "coding.trusted-workspace",
               root,
               :tui
             )

    assert selected.state == :ready_unlocked
    assert selected.binding.execution_policy.execution_policy_id == "coding.trusted-workspace"
    assert selected.binding.execution_policy.origin == :tui
  end

  test "keeps pending draft generation stable until all choices are ready", %{root: root} do
    source = Path.expand("test/fixtures/agents/trusted.json")
    assert {:ok, pending} = Selection.new(thread_id: "pending-choices", agent_source: source)
    assert pending.state == :needs_policy
    assert pending.generation == 0

    assert {:ok, pending} =
             Selection.select_model(pending, "ollama:llama3.2", :api)

    assert pending.state == :needs_policy
    assert pending.generation == 0

    assert {:ok, selected} =
             Selection.select_execution_policy(
               pending,
               "coding.trusted-workspace",
               root,
               :api
             )

    assert selected.state == :ready_unlocked
    assert selected.generation == 1
    assert selected.binding.model_id == "ollama:llama3.2"
    assert selected.binding.model_origin == :api
  end

  test "only a fully unused legacy session can rebind" do
    assert {:ok, source} = Jido.Console.AgentSource.resolve("builtin:jido")
    assert {:ok, session} = Jidoka.Session.Data.start(source.base_spec, session_id: "legacy-unused")

    assert {:rebind, ready} = Selection.resume(session, thread_id: session.session_id)
    assert ready.state == :ready_unlocked

    assert {:blocked, blocked} =
             Selection.resume(session,
               thread_id: session.session_id,
               legacy_events_present?: true
             )

    assert blocked.blocked_reason == :legacy_session_has_history

    conversation =
      Jidoka.Session.Conversation.new!(agent_state: Jidoka.Agent.State.new!(metadata: %{"prior" => true}))

    prior_work = [
      %{session | revision: 1},
      %{session | status: :running},
      %{session | requests: [%{}]},
      %{session | snapshots: [%{}]},
      %{session | result: :result},
      %{session | error: :error},
      %{session | lease: :lease},
      %{session | environment: :environment},
      %{session | lineage: :lineage},
      %{session | metadata: %{"prior" => true}},
      %{session | conversation: conversation}
    ]

    for used <- prior_work do
      assert {:blocked, blocked} = Selection.resume(used, thread_id: session.session_id)
      assert blocked.blocked_reason == :legacy_session_has_history
    end
  end

  test "blocks exact resume after source bytes change", %{root: root} do
    source = Path.join(root, "agent.json")
    File.cp!("test/fixtures/agents/valid.json", source)
    assert {:ok, selection} = Selection.new(thread_id: "file-resume", agent_source: source)
    assert {:ok, session} = Selection.start_session(selection, "file-resume")

    File.write!(source, File.read!(source) <> "\n")
    assert {:blocked, blocked} = Selection.resume(session, thread_id: "file-resume")
    assert blocked.state == :resume_blocked
    assert blocked.blocked_reason in [:agent_source_evidence_mismatch, :agent_source_changed]
  end

  test "locks one exact operation and rejects conflicting attach choices" do
    assert {:ok, selection} = Selection.new(thread_id: "selection-lock")

    command =
      Command.new!(
        id: "first-command",
        type: :submit,
        thread_id: "selection-lock",
        queue_item_id: "first-command",
        request_id: "first-request",
        text: "hello",
        payload: %{}
      )

    operation_id = Command.lock_operation_id(command)
    digest = Command.first_lock_digest(command, selection.manifest["binding_digest"])
    assert {:ok, locked} = Selection.lock(selection, operation_id, digest)
    assert locked.state == :locked
    assert locked.manifest["lock_operation_id"] == operation_id
    manifest = locked.manifest
    assert {:ok, ^manifest} = BindingManifest.validate(manifest)

    assert {:ok, empty} = BindingRequest.from_options([])
    assert :ok = Selection.match_request(locked, empty)

    assert {:ok, conflict} = BindingRequest.from_options(model: "ollama:llama3.2")
    assert {:error, {:binding_conflict, :model}} = Selection.match_request(locked, conflict)
  end
end
