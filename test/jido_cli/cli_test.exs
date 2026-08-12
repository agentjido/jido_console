defmodule Jido.CliTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule FakeTui do
    def run(opts) do
      send(Keyword.fetch!(opts, :test_pid), :tui_started)
      :ok
    end
  end

  defmodule ErrorTui do
    def run(opts), do: {:error, Keyword.fetch!(opts, :reason)}
  end

  defmodule FakeAutomation do
    def execute(args, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:automation_started, args})
      Keyword.get(opts, :automation_result, {:ok, %{status: :passed}})
    end
  end

  test "prints help" do
    assert capture_io(fn -> assert :ok = Jido.Cli.run(["--help"]) end) =~ "Usage:\n  jido"
  end

  test "prints version" do
    assert capture_io(fn -> assert :ok = Jido.Cli.run(["--version"]) end) == "jido 0.1.0\n"
  end

  test "prints command help" do
    for args <- [["run", "--help"], ["run", "-h"], ["eval", "--help"], ["eval", "-h"]] do
      assert capture_io(fn -> assert :ok = Jido.Cli.run(args) end) =~ "jido eval SUITE"
    end
  end

  test "rejects unknown options" do
    assert capture_io(:stderr, fn ->
             assert {:error, 1} = Jido.Cli.run(["--wat"])
           end) == "jido: unknown option: --wat\n"
  end

  test "rejects positional arguments" do
    assert capture_io(:stderr, fn ->
             assert {:error, 64} = Jido.Cli.run(["agent.yaml"])
           end) =~ "Usage:\n  jido"
  end

  test "starts the TUI with no arguments" do
    assert :ok = Jido.Cli.run([], tui: FakeTui, test_pid: self())
    assert_received :tui_started
  end

  test "sends run commands to the automation boundary" do
    args = ["run", "--agent", "agent.yml", "--input", "prompt.md"]

    assert :ok =
             Jido.Cli.run(args,
               automation: FakeAutomation,
               test_pid: self()
             )

    assert_received {:automation_started, ^args}
  end

  test "sends eval commands to the automation boundary" do
    args = ["eval", "suite.yml"]

    assert :ok =
             Jido.Cli.run(args,
               automation: FakeAutomation,
               test_pid: self()
             )

    assert_received {:automation_started, ^args}
  end

  test "maps failed evaluations and automation errors to exit statuses" do
    opts = [automation: FakeAutomation, test_pid: self()]

    failed_output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Cli.run(
                   ["eval", "suite.yml"],
                   opts ++
                     [
                       automation_result:
                         {:ok,
                          %{
                            status: :failed,
                            counts: %{failed: 2, errors: 1}
                          }}
                     ]
                 )
      end)

    assert failed_output =~ "2 failed, 1 errors"

    usage_output =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Cli.run(
                   ["run"],
                   opts ++ [automation_result: {:error, :usage, "missing agent"}]
                 )
      end)

    assert usage_output == "jido: missing agent\n"

    execution_output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Cli.run(
                   ["eval", "suite.yml"],
                   opts ++ [automation_result: {:error, :execution, "write failed"}]
                 )
      end)

    assert execution_output == "jido: write failed\n"
  end

  test "rejects an invalid automation boundary result" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Cli.run(["eval", "suite.yml"],
                   automation: FakeAutomation,
                   test_pid: self(),
                   automation_result: :invalid
                 )
      end)

    assert output =~ "invalid automation result"
  end

  test "defines the built-in agent" do
    assert Jido.Cli.DefaultAgent.spec().id == "jido"
  end

  test "main starts the application and prints help" do
    assert capture_io(fn -> assert :ok = Jido.Cli.main(["--help"]) end) =~ "Usage:"
  end

  test "formats TUI errors at the CLI boundary" do
    reasons = [
      {RuntimeError.exception("exception failure"), "exception failure"},
      {"text failure", "text failure"},
      {{:bad, :reason}, "bad"}
    ]

    for {reason, expected} <- reasons do
      output =
        capture_io(:stderr, fn ->
          assert {:error, 1} = Jido.Cli.run([], tui: ErrorTui, reason: reason)
        end)

      assert output =~ expected
    end
  end
end
