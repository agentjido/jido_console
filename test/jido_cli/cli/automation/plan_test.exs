defmodule Jido.Cli.Automation.PlanTest do
  use ExUnit.Case, async: false

  alias Jido.Cli.Automation.{Loader, Plan}

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido-cli-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "expands agents, models, scenarios, and trials in stable order", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_agent(Path.join(root, "b.yml"), "agent_b")
    write_scenario(Path.join(root, "one.yml"), "one")
    write_scenario(Path.join(root, "two.yml"), "two")

    suite_path = Path.join(root, "suite.yml")

    File.write!(suite_path, """
    version: 1
    suite:
      id: matrix
      agents:
        - key: a
          file: a.yml
        - key: b
          file: b.yml
      scenarios:
        - one.yml
        - two.yml
      models:
        - key: declared
          source: agent
        - key: pinned
          ref: openai:gpt-4o-mini
      matrix:
        repeats: 2
    """)

    assert {:ok, suite} = Loader.load_suite(suite_path)
    assert {:ok, plan} = Plan.build(suite, run_id: "run-fixed")
    assert length(plan.cells) == 16

    dimensions = Enum.map(plan.cells, & &1.dimensions)

    assert Enum.take(dimensions, 4) == [
             dimension("a", "agent_a", "declared", "one", 1),
             dimension("a", "agent_a", "declared", "one", 2),
             dimension("a", "agent_a", "declared", "two", 1),
             dimension("a", "agent_a", "declared", "two", 2)
           ]

    assert Enum.map(plan.cells, & &1.sequence) == Enum.to_list(1..16)
    assert Enum.all?(plan.cells, &(byte_size(&1.cell_id) == 64))
  end

  test "resolves a data-only profile and keeps host runtime injection separate", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a", "agent-profile")
    write_scenario(Path.join(root, "one.yml"), "one")
    suite = suite(root, "suite-profile")
    llm = fn _intent, _journal, _context -> {:ok, %{type: :final, content: "ok"}} end

    assert {:ok, %{cells: [cell]} = plan} =
             Plan.build(suite,
               run_id: "run-fixed",
               execution_profile_resolver: resolver(),
               runtime_opts: [llm: llm]
             )

    assert cell.execution_environment.request.profile_id == "agent-profile"
    assert cell.execution_environment.registration.profile.profile_id == "agent-profile"
    assert cell.runtime_opts[:llm] == llm

    [manifest_cell] = plan.manifest.cells
    assert manifest_cell.execution_environment.status == :resolved
    assert manifest_cell.execution_environment.requested.profile_id == "agent-profile"
    assert manifest_cell.execution_environment.resolved.profile_digest =~ "sha256:"
    assert manifest_cell.capability_replay.mode == :live
    assert manifest_cell.capability_replay.status == :not_replayed
    refute Map.has_key?(manifest_cell.execution_environment, :confirmed)
  end

  test "uses command, scenario, agent, suite, and none precedence", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a", "agent-profile")
    write_scenario(Path.join(root, "one.yml"), "one", "scenario-profile")

    suite =
      root
      |> suite("suite-profile")
      |> Map.put(:command_execution_profile, "command-profile")

    opts = [execution_profile_resolver: resolver(), run_id: "run-fixed"]

    assert profile_id(Plan.build(suite, opts)) == "command-profile"
    assert profile_id(Plan.build(%{suite | command_execution_profile: nil}, opts)) == "scenario-profile"

    no_scenario = put_in(suite.scenarios, [Map.put(hd(suite.scenarios), :execution_profile, nil)])
    assert profile_id(Plan.build(%{no_scenario | command_execution_profile: nil}, opts)) == "agent-profile"

    write_agent(Path.join(root, "a.yml"), "agent_a")
    assert profile_id(Plan.build(%{no_scenario | command_execution_profile: nil}, opts)) == "suite-profile"

    no_profile = %{no_scenario | command_execution_profile: nil, execution_profile: nil}
    assert {:ok, %{cells: [%{execution_environment: nil}]}} = Plan.build(no_profile, opts)
  end

  test "fails closed for missing, unknown, disabled, and insufficient profiles", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a", "restricted")
    write_scenario(Path.join(root, "one.yml"), "one")
    suite = suite(root, nil)

    assert {:error, {:missing_execution_profile_resolver, "restricted"}} = Plan.build(suite)

    assert {:error, %Jidoka.ExecutionEnvironment.Error{code: :unknown_profile}} =
             Plan.build(suite, execution_profile_resolver: fn _id, _opts -> {:error, :unknown_profile} end)

    assert {:error, %Jidoka.ExecutionEnvironment.Error{code: :disabled_profile}} =
             Plan.build(suite, execution_profile_resolver: resolver(enabled: false))

    assert {:error, %Jidoka.ExecutionEnvironment.Error{code: :insufficient_adapter_capability}} =
             Plan.build(suite, execution_profile_resolver: resolver(available: false))

    assert {:error, %Jidoka.ExecutionEnvironment.Error{code: :profile_resolution_failed}} =
             Plan.build(suite,
               execution_profile_resolver: fn _id, _opts -> raise "resolver failed" end
             )

    missing = put_in(suite.agents, [%{key: "missing", file: "/missing.yml"}])
    assert {:error, {:agent_load_failed, "/missing.yml", _reason}} = Plan.build(missing)
  end

  test "rejects an invalid model override and accepts generation options", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_scenario(Path.join(root, "one.yml"), "one")
    suite = suite(root, nil)

    invalid = %{
      suite
      | models: [
          %{key: "bad", source: :override, ref: "not a valid model", generation: nil}
        ]
    }

    assert {:error, {:model_override_failed, "a", "bad", _reason}} = Plan.build(invalid)

    valid = %{
      suite
      | models: [
          %{
            key: "cold",
            source: :override,
            ref: "openai:gpt-4o-mini",
            generation: %{"temperature" => 0.0}
          }
        ]
    }

    assert {:ok, %{cells: [cell]}} = Plan.build(valid, run_id: "run-fixed")
    assert cell.dimensions.model_key == "cold"
  end

  defp dimension(agent, spec, model, scenario, trial) do
    %{
      suite_id: "matrix",
      agent_key: agent,
      agent_spec_id: spec,
      scenario_id: scenario,
      model_key: model,
      model_ref: "openai:gpt-4o-mini",
      trial: trial
    }
  end

  defp suite(root, execution_profile) do
    %{
      id: "profile",
      path: "suite.yml",
      digest: "suite-digest",
      agents: [
        %{key: "a", file: Path.join(root, "a.yml")}
      ],
      scenarios: [Loader.load_scenario(Path.join(root, "one.yml")) |> elem(1)],
      models: [%{key: "declared", source: :agent, ref: nil, generation: nil}],
      repeats: 1,
      jobs: 1,
      execution_profile: execution_profile,
      command_execution_profile: nil,
      output: nil
    }
  end

  defp write_agent(path, id, execution_profile \\ nil) do
    profile = if execution_profile, do: "  execution_profile: #{execution_profile}\n", else: ""

    File.write!(path, """
    version: 1
    agent:
      id: #{id}
      model: openai:gpt-4o-mini
      instructions: Answer briefly.
    #{profile}
    """)
  end

  defp write_scenario(path, id, execution_profile \\ nil) do
    profile = if execution_profile, do: "  execution_profile: #{execution_profile}\n", else: ""

    File.write!(path, """
    version: 1
    scenario:
      id: #{id}
    #{profile}
      request:
        input:
          text: Hello
    """)
  end

  defp profile_id({:ok, %{cells: [%{execution_environment: environment}]}}),
    do: environment.request.profile_id

  defp resolver(opts \\ []) do
    fn profile_id, _resolver_opts -> {:ok, registration(profile_id, opts)} end
  end

  defp registration(profile_id, opts) do
    profile =
      Jidoka.ExecutionEnvironment.SecurityProfile.new!(
        profile_id: profile_id,
        revision: 1,
        digest: "sha256:" <> String.duplicate("a", 64),
        adapter_id: "test.adapter",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral
      )

    capabilities =
      Jidoka.ExecutionEnvironment.AdapterCapabilities.new!(
        adapter_id: "test.adapter",
        adapter_version: "1",
        available: Keyword.get(opts, :available, true),
        isolations: [:container],
        networks: [:disabled],
        workspaces: [:ephemeral]
      )

    Jidoka.ExecutionEnvironment.Registration.new!(
      profile: profile,
      adapter: __MODULE__,
      capabilities: capabilities,
      enabled: Keyword.get(opts, :enabled, true)
    )
  end
end
