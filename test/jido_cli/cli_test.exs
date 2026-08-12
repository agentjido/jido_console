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

  test "prints help" do
    assert capture_io(fn -> assert :ok = Jido.Cli.run(["--help"]) end) =~ "Usage:\n  jido"
  end

  test "prints version" do
    assert capture_io(fn -> assert :ok = Jido.Cli.run(["--version"]) end) == "jido 0.1.0\n"
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
