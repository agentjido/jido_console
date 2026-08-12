defmodule Jido.Cli.Automation.JSONLTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Automation.JSONL

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-jsonl-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "writes to a selected output device without a file directory" do
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(%{}, nil, output_device: device)
    assert :ok = JSONL.emit(sink, result("agent"))
    assert :ok = JSONL.finish(sink, %{})
    {_input, output} = StringIO.contents(device)
    assert Jason.decode!(String.trim(output))["schema"] == "jido.case-result"
  end

  test "accepts an empty directory and rejects unsafe output targets", %{root: root} do
    empty = Path.join(root, "empty")
    File.mkdir_p!(empty)
    {:ok, device} = StringIO.open("")

    assert {:ok, sink} = JSONL.open(%{run_id: "run"}, empty, output_device: device)
    assert File.regular?(Path.join(empty, "manifest.json"))
    assert :ok = JSONL.finish(sink, %{status: :passed})

    assert {:error, {:invalid_output_directory, 42}} = JSONL.open(%{}, 42)

    blocked = Path.join(root, "blocked")
    File.mkdir_p!(blocked)
    File.write!(Path.join(blocked, "keep"), "data")

    assert {:error, {:output_directory_not_empty, ^blocked, ["keep"]}} =
             JSONL.open(%{}, blocked)

    file = Path.join(root, "file")
    File.write!(file, "data")

    assert {:error, {:output_directory_unavailable, ^file, :enotdir}} =
             JSONL.open(%{}, file)
  end

  test "keeps explicit agent keys inside the output directory", %{root: root} do
    output = Path.join(root, "artifacts")
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(%{}, output, output_device: device)
    assert :ok = JSONL.emit(sink, result("../../Outside Agent"))

    assert [path] = Path.wildcard(Path.join(output, "by-agent/*.jsonl"))
    assert Path.dirname(path) == Path.join(output, "by-agent")
    refute File.exists?(Path.join(root, "Outside Agent.jsonl"))
  end

  defp result(agent_key) do
    %{
      schema: "jido.case-result",
      dimensions: %{agent_key: agent_key},
      execution: %{status: :ok}
    }
  end
end
