defmodule Jido.Console.ExtensionsAutomationIntegrationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Automation

  defmodule FakeEngine do
    @behaviour Jido.Console.Automation.Engine

    @impl true
    def start(cell, opts), do: {:ok, {cell, opts}}

    @impl true
    def await({cell, _opts}, _await_opts) do
      Jido.Console.Automation.Result.new(cell,
        execution: %{status: :ok, started_at: "2026-08-12T12:00:00Z", duration_ms: 1, turn_count: 0},
        evaluation: %{status: :unscored, assertion_count: 0, failed_assertion_count: 0}
      )
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :request_already_finished}
  end

  @hash "sha256:" <> String.duplicate("c", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-extension-automation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "run opens one fresh host and projects only namespaced portable data", %{root: root} do
    paths = write_run_files(root, "user")
    owner = self()

    resolver = fn "acme.fixture", _context ->
      {:ok,
       fn _binding, _config, _context ->
         send(owner, :extension_opened)

         {:ok, :instance,
          %{
            namespace: "acme.fixture",
            state: %{"count" => 1},
            result: %{"answer" => 42},
            ui_data: %{"panel" => "fixture"},
            close: fn _instance ->
              send(owner, :extension_closed)
              :ok
            end
          }}
       end}
    end

    llm = fn _intent, _journal, _context -> {:ok, %{type: :final, content: "Hello"}} end

    stdout =
      capture_io(fn ->
        assert {:ok, %{status: :passed}} =
                 Automation.execute(
                   ["run", "--agent", paths.agent, "--input", paths.input],
                   extension_record_files: [paths.records],
                   project_root: root,
                   built_in_extension_resolver: resolver,
                   runtime_opts: [llm: llm],
                   run_id: "extension-run"
                 )
      end)

    assert_receive :extension_opened
    assert_receive :extension_closed
    [result] = decode_jsonl(stdout)
    assert result["extensions"]["acme.fixture"]["result"] == %{"answer" => 42}
    assert result["extensions"]["acme.fixture"]["ui_data"] == %{"panel" => "fixture"}
    assert result["extensions"]["jido.cli.trust"]["status"] == "trusted"
    refute stdout =~ "command"
    refute stdout =~ "secret"
  end

  test "eval and run use the same trust resolver before execution", %{root: root} do
    paths = write_run_files(root, "user")
    scenario = Path.join(root, "scenario.yml")
    suite = Path.join(root, "suite.yml")
    write_scenario(scenario)

    File.write!(suite, """
    version: 1
    suite:
      id: extension_suite
      agents:
        - key: fixture
          file: agent.yml
      scenarios:
        - scenario.yml
      models:
        - key: declared
          source: agent
      run:
        jobs: 1
    """)

    owner = self()

    resolver = fn "acme.fixture", _context ->
      send(owner, :resolved)
      {:ok, fn _binding, _config, _context -> {:ok, :instance, %{namespace: "acme.fixture"}} end}
    end

    engine = FakeEngine

    capture_io(fn ->
      assert {:ok, _summary} =
               Automation.execute(["run", "--agent", paths.agent, "--input", paths.input],
                 engine: engine,
                 extension_record_files: [paths.records],
                 project_root: root,
                 built_in_extension_resolver: resolver
               )
    end)

    capture_io(fn ->
      assert {:ok, _summary} =
               Automation.execute(["eval", suite],
                 engine: engine,
                 extension_record_files: [paths.records],
                 project_root: root,
                 built_in_extension_resolver: resolver
               )
    end)

    assert_receive :resolved
    assert_receive :resolved
  end

  test "untrusted project records fail with status 64 before JSONL", %{root: root} do
    paths = write_run_files(root, "project")

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(
              self(),
              {:status,
               Jido.Console.run(
                 ["run", "--agent", paths.agent, "--input", paths.input],
                 extension_record_files: [paths.records],
                 project_root: root
               )}
            )
          end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:status, {:error, 64}}
    assert_received {:stderr, stderr}
    assert stderr =~ "untrusted"
    assert stdout == ""
  end

  test "extension close failure gives one valid case error and status 1", %{root: root} do
    paths = write_run_files(root, "user")

    resolver = fn _id, _context ->
      {:ok,
       fn _binding, _config, _context ->
         {:ok, :instance,
          %{
            namespace: "acme.fixture",
            close: fn _instance -> {:error, :close_failed} end
          }}
       end}
    end

    llm = fn _intent, _journal, _context -> {:ok, %{type: :final, content: "Hello"}} end

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(
              self(),
              {:status,
               Jido.Console.run(
                 ["run", "--agent", paths.agent, "--input", paths.input],
                 extension_record_files: [paths.records],
                 project_root: root,
                 built_in_extension_resolver: resolver,
                 runtime_opts: [llm: llm]
               )}
            )
          end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:status, {:error, 1}}
    assert_received {:stderr, stderr}
    assert stderr =~ "automated run failed"
    [result] = decode_jsonl(stdout)
    assert result["execution"]["status"] == "error"
    assert result["error"]
  end

  defp write_run_files(root, scope) do
    agent = Path.join(root, "agent.yml")
    input = Path.join(root, "input.txt")
    records = Path.join(root, "extensions.json")

    File.write!(agent, """
    version: 1
    agent:
      id: extension_agent
      model: test:model
    extensions:
      - id: acme.fixture
    """)

    File.write!(input, "Hello")

    File.write!(
      records,
      Jason.encode!(%{
        "version" => 1,
        "extensions" => [
          %{
            "id" => "acme.fixture",
            "source" => "built_in",
            "source_ref" => "registry:acme-fixture",
            "release" => "1.0.0",
            "sha256" => @hash,
            "permissions" => ["results", "state", "ui_data"],
            "capabilities" => ["acme.fixture.run"],
            "modes" => ["interactive", "automation"],
            "scope" => scope
          }
        ]
      })
    )

    %{agent: agent, input: input, records: records}
  end

  defp write_scenario(path) do
    File.write!(path, """
    version: 1
    scenario:
      id: extension_scenario
      request:
        input:
          text: Hello
    """)
  end

  defp decode_jsonl(text) do
    text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end
