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

  test "resolves a trusted runtime profile", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_scenario(Path.join(root, "one.yml"), "one")

    suite = %{
      id: "profile",
      path: "suite.yml",
      digest: "suite-digest",
      agents: [
        %{key: "a", file: Path.join(root, "a.yml"), runtime_profile: "tools"}
      ],
      scenarios: [Loader.load_scenario(Path.join(root, "one.yml")) |> elem(1)],
      models: [%{key: "declared", source: :agent, ref: nil, generation: nil}],
      repeats: 1,
      jobs: 1,
      output: nil
    }

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end
    profiles = %{"tools" => [run_opts: [llm: llm]]}

    assert {:ok, %{cells: [cell]}} =
             Plan.build(suite, run_id: "run-fixed", runtime_profiles: profiles)

    assert cell.runtime_opts[:llm] == llm
  end

  test "accepts map, list, application, and atom runtime profiles", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_scenario(Path.join(root, "one.yml"), "one")
    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end
    suite = suite(root, "tools")

    assert {:ok, %{cells: [%{runtime_opts: opts}]}} =
             Plan.build(suite,
               runtime_profiles: %{"tools" => %{"import_opts" => [], "run_opts" => [llm: llm]}}
             )

    assert opts[:llm] == llm

    assert {:ok, %{cells: [%{runtime_opts: opts}]}} =
             Plan.build(suite, runtime_profiles: [tools: [run_opts: [llm: llm]]])

    assert opts[:llm] == llm

    previous = Application.get_env(:jido_cli, :automation_runtime_profiles)
    Application.put_env(:jido_cli, :automation_runtime_profiles, %{tools: [run_opts: [llm: llm]]})

    on_exit(fn ->
      if previous do
        Application.put_env(:jido_cli, :automation_runtime_profiles, previous)
      else
        Application.delete_env(:jido_cli, :automation_runtime_profiles)
      end
    end)

    assert {:ok, %{run_id: "run-" <> _, cells: [%{runtime_opts: opts}]}} = Plan.build(suite)
    assert opts[:llm] == llm
  end

  test "rejects missing or invalid profiles and agent files", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_scenario(Path.join(root, "one.yml"), "one")
    suite = suite(root, "tools")

    assert {:error, {:unknown_runtime_profile, "tools"}} =
             Plan.build(suite, runtime_profiles: %{})

    assert {:error, {:unknown_runtime_profile, "tools"}} =
             Plan.build(suite, runtime_profiles: :invalid)

    assert {:error, {:invalid_runtime_profile, "tools", :invalid}} =
             Plan.build(suite, runtime_profiles: %{"tools" => :invalid})

    assert {:error, {:invalid_runtime_profile, _profile}} =
             Plan.build(suite, runtime_profiles: %{"tools" => [run_opts: %{}]})

    missing = put_in(suite.agents, [%{key: "missing", file: "/missing.yml", runtime_profile: nil}])
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

  defp suite(root, runtime_profile) do
    %{
      id: "profile",
      path: "suite.yml",
      digest: "suite-digest",
      agents: [
        %{key: "a", file: Path.join(root, "a.yml"), runtime_profile: runtime_profile}
      ],
      scenarios: [Loader.load_scenario(Path.join(root, "one.yml")) |> elem(1)],
      models: [%{key: "declared", source: :agent, ref: nil, generation: nil}],
      repeats: 1,
      jobs: 1,
      output: nil
    }
  end

  defp write_agent(path, id) do
    File.write!(path, """
    version: 1
    agent:
      id: #{id}
      model: openai:gpt-4o-mini
      instructions: Answer briefly.
    """)
  end

  defp write_scenario(path, id) do
    File.write!(path, """
    version: 1
    scenario:
      id: #{id}
      request:
        input:
          text: Hello
    """)
  end
end
