defmodule Jido.Console.ExecutionPolicy.SelectionTest do
  use ExUnit.Case, async: false

  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.{Consent, Registry, Selection}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-policy-root-#{System.unique_integer([:positive])}")
    other = Path.join(System.tmp_dir!(), "jido-policy-other-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(other) end)
    %{registry: Registry.new!(), root: root, other: other}
  end

  test "implements the complete request and direct-choice matrix", context do
    restricted = ExecutionPolicy.restricted_id()
    trusted = ExecutionPolicy.trusted_id()
    trusted_choice = direct(trusted, :cli)
    restricted_choice = direct(restricted, :api)

    assert_selected(restricted, resolve(context))

    assert_selected(
      restricted,
      resolve(context, application_proposal: restricted)
    )

    assert {:error, {:consent_required, ^trusted}} =
             resolve(context, application_proposal: trusted)

    assert_selected(restricted, resolve(context, agent_request: restricted))

    assert_selected(
      restricted,
      resolve(context, agent_request: restricted, direct_choice: restricted_choice)
    )

    assert {:error, {:consent_required, ^trusted}} =
             resolve(context, agent_request: trusted)

    assert_selected(
      trusted,
      resolve(context, direct_choice: trusted_choice, project_root: context.root)
    )

    assert_selected(
      trusted,
      resolve(context,
        agent_request: trusted,
        direct_choice: trusted_choice,
        project_root: context.root
      )
    )

    assert {:error, {:execution_policy_mismatch, ^trusted, ^restricted}} =
             resolve(context,
               agent_request: trusted,
               direct_choice: restricted_choice,
               project_root: context.root
             )

    assert {:error, {:unknown_execution_policy, "missing"}} =
             resolve(context, agent_request: "missing", direct_choice: trusted_choice)

    assert {:error, {:unknown_execution_policy, "missing"}} =
             resolve(context,
               direct_choice: direct("missing", :cli),
               project_root: context.root
             )
  end

  test "an agent request replaces a proposal and a direct choice overrides only a proposal", context do
    restricted = ExecutionPolicy.restricted_id()
    trusted = ExecutionPolicy.trusted_id()

    assert_selected(
      restricted,
      resolve(context, agent_request: restricted, application_proposal: trusted)
    )

    assert_selected(
      trusted,
      resolve(context,
        application_proposal: restricted,
        direct_choice: direct(trusted, :tui),
        project_root: context.root
      )
    )

    assert {:error, {:execution_policy_mismatch, ^restricted, ^trusted}} =
             resolve(context,
               agent_request: restricted,
               application_proposal: restricted,
               direct_choice: direct(trusted, :api),
               project_root: context.root
             )

    assert {:error, {:unknown_execution_policy, "missing"}} =
             resolve(context, application_proposal: "missing")
  end

  test "rejects forged consent and accepts each trusted direct origin", context do
    trusted = ExecutionPolicy.trusted_id()

    forged = %{execution_policy_id: trusted, origin: :cli}
    assert {:error, :invalid_execution_policy_consent} = resolve(context, direct_choice: forged)

    forged_struct = %Consent{execution_policy_id: trusted, origin: :document, legacy?: false}
    assert {:error, :invalid_execution_policy_consent} = resolve(context, direct_choice: forged_struct)

    for origin <- [:cli, :api, :tui] do
      assert_selected(
        trusted,
        resolve(context,
          direct_choice: direct(trusted, origin),
          project_root: context.root
        )
      )
    end
  end

  test "normalizes the local alias before consent, root checks, and evidence", context do
    choice = direct("coding.local", :cli)

    assert {:ok, selection} =
             resolve(context, agent_request: "coding.local", direct_choice: choice, project_root: context.root)

    assert selection.execution_policy_id == "coding.trusted-workspace"
    assert selection.workspace.root == Path.expand(context.root)
    assert selection.evidence["execution_policy_id"] == "coding.trusted-workspace"
  end

  test "rejects a missing, invalid, or mismatched trusted workspace root", context do
    trusted = ExecutionPolicy.trusted_id()
    choice = direct(trusted, :cli)

    assert {:error, {:execution_policy_root_required, ^trusted}} =
             resolve(context, direct_choice: choice)

    assert {:error, {:invalid_execution_policy_root, ^trusted}} =
             resolve(context, direct_choice: choice, project_root: Path.join(context.root, "missing"))

    assert {:error, {:execution_policy_root_mismatch, ^trusted}} =
             resolve(context,
               direct_choice: choice,
               project_root: context.root,
               workspace_root: context.other
             )
  end

  test "selection is resource-free and does not create paths, managers, bindings, or ports", context do
    missing = Path.join(context.root, "must-not-be-created")
    before_links = links()
    before_ports = MapSet.new(:erlang.ports())

    assert_selected(ExecutionPolicy.restricted_id(), resolve(context, project_root: missing))
    refute File.exists?(missing)
    assert links() == before_links
    assert MapSet.new(:erlang.ports()) == before_ports

    assert {:error, {:consent_required, "coding.trusted-workspace"}} =
             resolve(context, agent_request: "coding.trusted-workspace", project_root: missing)

    refute File.exists?(missing)
    assert links() == before_links
    assert MapSet.new(:erlang.ports()) == before_ports
  end

  test "stored consent is exact to one thread and the current registry evidence", context do
    trusted = ExecutionPolicy.trusted_id()

    assert {:ok, selected} =
             resolve(context,
               direct_choice: direct(trusted, :api),
               project_root: context.root
             )

    assert {:ok, stored} = ExecutionPolicy.store_consent(selected, "thread-1")

    assert_selected(
      trusted,
      resolve(context,
        agent_request: trusted,
        stored_consent: stored,
        thread_id: "thread-1",
        project_root: context.root
      )
    )

    assert {:error, {:consent_required, ^trusted}} =
             resolve(context,
               agent_request: trusted,
               stored_consent: stored,
               thread_id: "thread-2",
               project_root: context.root
             )

    changed = Registry.new!(adapter_version: "2")

    assert {:error, {:consent_required, ^trusted}} =
             Selection.resolve(
               registry: changed,
               agent_request: trusted,
               stored_consent: stored,
               thread_id: "thread-1",
               project_root: context.root
             )
  end

  test "stored consent can be minted only from an untampered direct selection", context do
    trusted = ExecutionPolicy.trusted_id()

    assert {:ok, selected} =
             resolve(context,
               direct_choice: direct(trusted, :api),
               project_root: context.root
             )

    forged_map = %{
      state: selected.state,
      execution_policy_id: selected.execution_policy_id,
      evidence: selected.evidence,
      direct_choice: selected.direct_choice
    }

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(forged_map, "thread-1")

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(%{selected | direct_choice: nil}, "thread-1")

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(
               %{selected | direct_choice: direct(ExecutionPolicy.restricted_id(), :api)},
               "thread-1"
             )

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(
               %{selected | evidence: Map.put(selected.evidence, "evidence_digest", "sha256:forged")},
               "thread-1"
             )

    changed_workspace = %{
      selected.workspace
      | minor_device: selected.workspace.minor_device + 1
    }

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(
               %{selected | workspace: changed_workspace},
               "thread-1"
             )

    assert {:ok, application_selection} =
             resolve(context, application_proposal: ExecutionPolicy.restricted_id())

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(application_selection, "thread-1")

    assert {:ok, stored} = ExecutionPolicy.store_consent(selected, "thread-1")

    assert {:ok, resumed} =
             resolve(context,
               agent_request: trusted,
               stored_consent: stored,
               thread_id: "thread-1",
               project_root: context.root
             )

    assert {:error, :invalid_execution_policy_selection} =
             ExecutionPolicy.store_consent(resumed, "thread-1")
  end

  test "configured registry modules load before capability inspection" do
    _purged_old_code = :code.purge(Registry)
    assert :code.delete(Registry)
    _purged_deleted_code = :code.purge(Registry)
    refute Code.loaded?(Registry)

    assert_selected(
      ExecutionPolicy.restricted_id(),
      Selection.resolve(registry: Registry, application_proposal: nil)
    )

    assert Code.loaded?(Registry)
  end

  test "same-file identity includes the minor device", context do
    assert {:ok, selected} =
             resolve(context,
               direct_choice: direct(ExecutionPolicy.trusted_id(), :cli),
               project_root: context.root
             )

    changed_minor = %{selected.workspace | minor_device: selected.workspace.minor_device + 1}

    refute Selection.same_workspace_identity?(selected.workspace, changed_minor)
    assert Selection.same_workspace_identity?(selected.workspace, selected.workspace)
  end

  defp direct(id, origin) do
    {:ok, choice} = ExecutionPolicy.direct_choice(id, origin)
    choice
  end

  defp resolve(context, opts \\ []) do
    Selection.resolve(Keyword.put(opts, :registry, context.registry))
  end

  defp assert_selected(expected, {:ok, selection}) do
    assert selection.state == :selected
    assert selection.execution_policy_id == expected
    assert %Jidoka.ExecutionEnvironment.Selection{} = selection.jidoka_selection
  end

  defp links do
    {:links, links} = Process.info(self(), :links)
    MapSet.new(links)
  end
end
