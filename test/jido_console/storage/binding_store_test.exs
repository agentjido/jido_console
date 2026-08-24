defmodule Jido.Console.Storage.BindingStoreTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{BindingManifest, Command, Event, Selection}
  alias Jido.Console.Storage
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jidoka.Session.Store

  defmodule DyingWriter do
    use GenServer

    def start, do: GenServer.start(__MODULE__, nil)
    def init(nil), do: {:ok, nil}
    def handle_call(_request, _from, state), do: {:stop, :simulated_writer_exit, state}
  end

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-binding-store-#{suffix}")
    writer = unique(:writer, suffix)

    opts = [
      name: unique(:supervisor, suffix),
      lock: unique(:lock, suffix),
      writer: writer,
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    storage_opts = [writer: writer, deadline: 5_000]
    store = Storage.session_store(storage_opts)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
      File.rm_rf(root)
    end)

    %{root: root, store: store, storage_opts: storage_opts}
  end

  test "persists unlocked draft changes with revision and generation compare-and-set", context do
    {selection, session} = stored_draft(context, "draft-cas")
    assert {:ok, changed} = Selection.select_model(selection, "ollama:llama3.2", :api)
    assert {:ok, incoming} = Selection.put_draft(changed, session)

    assert {:ok, stored} =
             Storage.put_binding_draft(incoming, session.revision, selection.generation, context.storage_opts)

    assert stored.revision == 1
    assert {:ok, manifest} = BindingManifest.fetch(stored)
    assert manifest["draft_generation"] == 1
    assert manifest["model"] == %{"id" => "ollama:llama3.2", "origin" => "api"}

    assert {:error, {:stale_binding_revision, 0, 1}} =
             Storage.put_binding_draft(incoming, 0, 0, context.storage_opts)
  end

  test "locks the binding and first prompt atomically and retries exact input", context do
    {selection, session} = stored_draft(context, "first-lock")
    {locked, locked_session, event, operation_id} = lock_input(selection, session, "first")

    assert {:ok, %{session: committed, event: stored, duplicate: false}} =
             Storage.lock_first_prompt(
               locked_session,
               event,
               operation_id,
               session.revision,
               selection.generation,
               context.storage_opts
             )

    assert stored.sequence == 1
    assert committed.revision == 1
    assert {:ok, manifest} = BindingManifest.fetch(committed)
    assert manifest["lock_state"] == "locked"
    assert manifest == locked.manifest

    assert {:ok, %{session: ^committed, event: ^stored, duplicate: true}} =
             Storage.lock_first_prompt(
               locked_session,
               event,
               operation_id,
               session.revision,
               selection.generation,
               context.storage_opts
             )

    assert {:ok, %{events: [^stored]}} =
             Storage.thread_events(session.session_id, context.storage_opts)
  end

  test "rolls back every injected first-lock write failure", context do
    for stage <- [:before_session_write, :after_session_write, :before_event_write, :after_event_write] do
      thread_id = "rollback-#{stage}"
      {selection, session} = stored_draft(context, thread_id)
      {_locked, locked_session, event, operation_id} = lock_input(selection, session, Atom.to_string(stage))

      assert {:error, {:injected_storage_failure, ^stage}} =
               Storage.lock_first_prompt(
                 locked_session,
                 event,
                 operation_id,
                 session.revision,
                 selection.generation,
                 Keyword.put(context.storage_opts, :failure_stage, stage)
               )

      assert {:ok, unchanged} = Store.get_session(context.store, thread_id)
      assert unchanged == session
      assert {:ok, %{events: []}} = Storage.thread_events(thread_id, context.storage_opts)
    end
  end

  test "serializes competing first locks and rejects locked generic spec changes", context do
    {selection, session} = stored_draft(context, "lock-race")

    inputs =
      for suffix <- ["a", "b"] do
        lock_input(selection, session, suffix)
      end

    results =
      inputs
      |> Enum.map(fn {_locked, locked_session, event, operation_id} ->
        Task.async(fn ->
          Storage.lock_first_prompt(
            locked_session,
            event,
            operation_id,
            session.revision,
            selection.generation,
            context.storage_opts
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, %{duplicate: false}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:binding_lock_conflict, _}}, &1)) == 1

    assert {:ok, committed} = Store.get_session(context.store, session.session_id)
    changed = %{committed | spec: selection.binding.base_spec}
    assert {:error, :locked_binding_mutation_forbidden} = Store.put_session(context.store, changed)
  end

  test "installs a runtime spec only with exact locked evidence", context do
    {selection, session} = stored_draft(context, "runtime-install")
    {_locked, locked_session, event, operation_id} = lock_input(selection, session, "runtime")

    assert {:ok, %{session: committed}} =
             Storage.lock_first_prompt(
               locked_session,
               event,
               operation_id,
               session.revision,
               selection.generation,
               context.storage_opts
             )

    assert {:ok, manifest} = BindingManifest.fetch(committed)
    runtime_spec = %{committed.spec | instructions: committed.spec.instructions <> "\nRuntime."}
    incoming = %{committed | spec: runtime_spec}

    assert {:error, :runtime_binding_evidence_mismatch} =
             Storage.install_runtime_spec(
               incoming,
               manifest["binding_digest"],
               "sha256:" <> String.duplicate("0", 64),
               context.storage_opts
             )

    assert {:ok, ^committed} = Store.get_session(context.store, committed.session_id)

    assert {:ok, installed} =
             Storage.install_runtime_spec(
               incoming,
               manifest["binding_digest"],
               manifest["runtime_definition_fingerprint"],
               context.storage_opts
             )

    assert installed.spec == runtime_spec
    assert {:ok, ^manifest} = BindingManifest.fetch(installed)
  end

  test "reports a writer exit during first lock as an unknown write", context do
    {selection, session} = stored_draft(context, "writer-exit")
    {_locked, locked_session, event, operation_id} = lock_input(selection, session, "writer-exit")
    assert {:ok, writer} = DyingWriter.start()

    assert {:error, {:write_unknown, ^operation_id}} =
             Storage.lock_first_prompt(
               locked_session,
               event,
               operation_id,
               session.revision,
               selection.generation,
               writer: writer,
               deadline: 5_000
             )
  end

  defp stored_draft(context, thread_id) do
    assert {:ok, selection} = Selection.new(thread_id: thread_id)
    assert {:ok, session} = Selection.start_session(selection, thread_id)
    assert {:ok, ^session} = Store.put_session(context.store, session)
    {selection, session}
  end

  defp lock_input(selection, session, suffix) do
    command =
      Command.new!(
        id: "command-#{suffix}",
        type: :submit,
        thread_id: session.session_id,
        queue_item_id: "command-#{suffix}",
        request_id: "request-#{suffix}",
        text: "prompt-#{suffix}",
        payload: %{"context" => %{}}
      )

    operation_id = Command.lock_operation_id(command)
    digest = Command.first_lock_digest(command, selection.manifest["binding_digest"])
    assert {:ok, locked} = Selection.lock(selection, operation_id, digest)
    assert {:ok, locked_session} = BindingManifest.put(%{session | revision: session.revision + 1}, locked.manifest)

    event =
      Event.new!(
        id: Event.event_id(session.session_id, command.queue_item_id, "prompt_queued"),
        session_id: session.session_id,
        queue_item_id: command.queue_item_id,
        request_id: command.request_id,
        type: "prompt_queued",
        jidoka_revision: locked_session.revision,
        payload: %{
          "input" => command.text,
          "context" => %{},
          "command_digest" => Command.digest(command),
          "binding_digest" => locked.manifest["binding_digest"],
          "lock_operation_id" => operation_id,
          "first_prompt_command_digest" => digest
        }
      )

    {locked, locked_session, event, operation_id}
  end

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")
end
