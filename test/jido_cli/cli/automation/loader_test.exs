defmodule Jido.Cli.Automation.LoaderTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Automation.Loader

  setup do
    root = tmp_dir("loader")
    File.mkdir_p!(Path.join(root, "prompts"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "loads ordered turns and resolves paths from the scenario file", %{root: root} do
    File.write!(Path.join(root, "prompts/first.md"), "Remember Atlas.\n")

    scenario_path = Path.join(root, "scenario.yml")

    File.write!(scenario_path, """
    version: 1
    scenario:
      id: remember_project
      context:
        value:
          tenant: acme
      turns:
        - id: remember
          input:
            file: prompts/first.md
          assertions:
            contains: Atlas
        - id: recall
          input:
            text: What is the project name?
          context:
            value:
              locale: en
          assertions:
            equals: Atlas
    """)

    assert {:ok, scenario} = Loader.load_scenario(scenario_path)
    assert scenario.id == "remember_project"
    assert Enum.map(scenario.turns, & &1.id) == ["remember", "recall"]
    assert hd(scenario.turns).input == "Remember Atlas.\n"
    assert Enum.at(scenario.turns, 1).context == %{"tenant" => "acme", "locale" => "en"}
  end

  test "supports the one-turn request form", %{root: root} do
    scenario_path = Path.join(root, "single.yml")

    File.write!(scenario_path, """
    version: 1
    scenario:
      id: single
      request:
        input:
          text: Hello
      assertions:
        contains: Hi
    """)

    assert {:ok, %{turns: [turn]}} = Loader.load_scenario(scenario_path)
    assert turn.id == "turn-1"
    assert turn.assertions == %{contains: "Hi"}
  end

  test "loads a suite matrix and referenced scenarios", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_agent(Path.join(root, "b.yml"), "agent_b")
    write_single_scenario(Path.join(root, "scenario.yml"))

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
        - file: scenario.yml
      models:
        - key: declared
          source: agent
        - key: override
          ref: openai:gpt-4o-mini
      matrix:
        repeats: 2
      run:
        jobs: 3
        output: artifacts
    """)

    assert {:ok, suite} = Loader.load_suite(suite_path)
    assert suite.id == "matrix"
    assert length(suite.agents) == 2
    assert length(suite.models) == 2
    assert suite.repeats == 2
    assert suite.jobs == 3
    assert suite.output == Path.join(root, "artifacts")
  end

  test "loads JSON, standard input, file context, and shorthand entries", %{root: root} do
    context_path = Path.join(root, "context.json")
    File.write!(context_path, Jason.encode!(%{region: "west"}))

    scenario_path = Path.join(root, "scenario.json")

    File.write!(
      scenario_path,
      Jason.encode!(%{
        version: 1,
        scenario: %{
          id: "json_case",
          context: %{file: "context.json"},
          turns: [
            %{
              input: "Hello",
              assertions: %{contains: ["Hello", "world"], operation_called: "lookup"}
            }
          ]
        }
      })
    )

    assert {:ok, %{turns: [turn]}} = Loader.load_scenario(scenario_path)
    assert turn.context == %{"region" => "west"}
    assert turn.assertions.operation_called == "lookup"

    {:ok, device} = StringIO.open("Input from standard input")

    assert {:ok, %{id: "stdin", turns: [stdin_turn]}} =
             Loader.scenario_from_input("-", input_device: device)

    assert stdin_turn.input == "Input from standard input"

    write_agent(Path.join(root, "simple.yml"), "simple")

    suite_path = Path.join(root, "shorthand.yml")

    File.write!(suite_path, """
    suite:
      id: shorthand
      agents:
        - simple.yml
      scenarios:
        - scenario.json
      models:
        - openai:gpt-4o-mini
    """)

    assert {:ok, suite} = Loader.load_suite(suite_path)
    assert [%{key: "simple"}] = suite.agents
    assert [%{source: :override, ref: "openai:gpt-4o-mini"}] = suite.models
  end

  test "uses declared models and reads one input file", %{root: root} do
    write_agent(Path.join(root, "agent.yml"), "agent")
    write_single_scenario(Path.join(root, "scenario.yml"))
    File.write!(Path.join(root, "prompt.txt"), "File input")

    File.write!(Path.join(root, "suite.yml"), """
    version: 1
    suite:
      id: defaults
      agents:
        - agent.yml
      scenarios:
        - scenario.yml
    """)

    assert {:ok, %{models: [%{source: :agent}]}} =
             Loader.load_suite(Path.join(root, "suite.yml"))

    assert {:ok, %{id: "prompt", turns: [%{input: "File input"}]}} =
             Loader.scenario_from_input(Path.join(root, "prompt.txt"))
  end

  test "rejects invalid scenario forms and assertions", %{root: root} do
    cases = [
      {"missing.yml", "version: 1\nscenario:\n  id: missing\n", :missing_scenario_turns},
      {"empty.yml", "version: 1\nscenario:\n  id: empty\n  turns: []\n", :invalid_turns},
      {"bad-turn.yml", "version: 1\nscenario:\n  id: bad\n  turns: [text]\n", :invalid_turn},
      {"bad-input.yml", "version: 1\nscenario:\n  id: bad\n  turns:\n    - input: 3\n",
       :invalid_text_source},
      {"bad-assertion.yml",
       "version: 1\nscenario:\n  id: bad\n  request:\n    input: Hello\n  assertions:\n    score: 1\n",
       :unsupported_assertions}
    ]

    for {name, contents, expected} <- cases do
      path = Path.join(root, name)
      File.write!(path, contents)
      assert {:error, reason} = Loader.load_scenario(path)
      assert inspect(reason) =~ Atom.to_string(expected)
    end
  end

  test "rejects invalid suite forms", %{root: root} do
    write_single_scenario(Path.join(root, "scenario.yml"))

    cases = [
      {"agents", "agents: []", :invalid_suite_agents},
      {"scenarios", "agents: [42]\n  scenarios: []", :invalid_suite_agent},
      {"models", "agents: [agent.yml]\n  scenarios: [scenario.yml]\n  models: []",
       :invalid_suite_models},
      {"repeats", "agents: [agent.yml]\n  scenarios: [scenario.yml]\n  repeats: 0",
       :invalid_positive_integer}
    ]

    for {name, body, expected} <- cases do
      path = Path.join(root, "#{name}.yml")
      File.write!(path, "version: 1\nsuite:\n  id: bad\n  #{body}\n")
      assert {:error, reason} = Loader.load_suite(path)
      assert inspect(reason) =~ Atom.to_string(expected)
    end
  end

  test "rejects unsupported versions, duplicate ids, and large files", %{root: root} do
    path = Path.join(root, "version.yml")
    File.write!(path, "version: 2\nscenario:\n  id: bad\n")

    assert {:error, {:unsupported_document_version, ^path, 2, 1}} =
             Loader.load_scenario(path)

    duplicate = Path.join(root, "duplicate.yml")

    File.write!(duplicate, """
    scenario:
      id: duplicate
      turns:
        - id: same
          input: One
        - id: same
          input: Two
    """)

    assert {:error, {:duplicate_id, :turn, "same"}} = Loader.load_scenario(duplicate)

    large = Path.join(root, "large.yml")
    File.write!(large, String.duplicate("a", 20))

    assert {:error, {:file_read_failed, ^large, {:file_too_large, ^large, 20, 10}}} =
             Loader.load_scenario(large, max_file_bytes: 10)
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

  defp write_single_scenario(path) do
    File.write!(path, """
    version: 1
    scenario:
      id: hello
      request:
        input:
          text: Hello
    """)
  end

  defp tmp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "jido-cli-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
