defmodule Jido.Console.AgentSourceTest do
  use ExUnit.Case, async: false

  alias Jido.Console.AgentSource
  alias Jido.Console.AgentSource.Record
  alias Jido.Console.Digest

  @fixtures Path.expand("../fixtures/agents", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "jido-agent-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "resolves the exact built-in source to one host record" do
    assert {:ok, %Record{} = first} = AgentSource.resolve("builtin:jido", startup_cwd: @fixtures)
    assert {:ok, %Record{} = second} = AgentSource.resolve("builtin:jido", startup_cwd: "/")

    assert first == second
    assert first.identity == "builtin:jido"
    assert first.kind == :builtin
    assert first.format == :compiled
    assert first.agent_id == "jido"
    assert first.label == "Jido"
    assert first.byte_size > 0
    assert first.digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert first.base_spec_digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert %Jidoka.Agent.Spec{id: "jido"} = first.base_spec
    assert Jidoka.Config.model_ref(first.base_spec.model) == "openai:gpt-4.1-mini"
  end

  test "resolves JSON, YAML, and YML through the same Spec boundary" do
    for name <- ~w(valid.json valid.yaml valid.yml) do
      path = Path.join(@fixtures, name)
      contents = File.read!(path)

      assert {:ok, %Record{} = record} = AgentSource.resolve(path, startup_cwd: "/")
      assert %Jidoka.Agent.Spec{id: "file_agent"} = record.base_spec
      assert record.agent_id == "file_agent"
      assert record.kind == :file
      assert record.format in [:json, :yaml]
      assert record.byte_size == byte_size(contents)
      assert record.digest == Digest.portable(contents)
      assert record.base_spec_digest =~ ~r/^sha256:[0-9a-f]{64}$/
      assert record.identity.path == Path.expand(path)
      assert is_integer(record.identity.inode)
      assert record.label == name
    end
  end

  test "uses the captured startup directory after the process cwd changes", %{root: root} do
    source = Path.join(root, "relative agent.JSON")
    File.cp!(Path.join(@fixtures, "valid.json"), source)
    other = Path.join(root, "other")
    File.mkdir_p!(other)

    File.cd!(other, fn ->
      assert {:ok, record} =
               AgentSource.resolve("relative agent.JSON", startup_cwd: root)

      assert record.format == :json
      assert record.identity.inode == File.stat!(source).inode
      assert Path.basename(record.identity.path) == "relative agent.JSON"
      assert record.label == "relative agent.JSON"
    end)
  end

  test "accepts case-insensitive extensions and rejects every other source form", %{root: root} do
    for extension <- ~w(JSON YAML YML JsOn yAmL yMl) do
      path = Path.join(root, "agent.#{extension}")
      fixture = if String.downcase(extension) == "json", do: "valid.json", else: "valid.yaml"
      File.cp!(Path.join(@fixtures, fixture), path)
      assert {:ok, %Record{}} = AgentSource.resolve(path, startup_cwd: root)
    end

    assert {:error, :unknown_builtin_agent} = AgentSource.resolve("builtin:other", startup_cwd: root)
    assert {:error, :invalid_agent_source} = AgentSource.resolve("BUILTIN:jido", startup_cwd: root)

    assert {:error, :unsupported_agent_source_format} =
             AgentSource.resolve("agent.txt", startup_cwd: root)
  end

  test "document metadata cannot forge host provenance" do
    path = Path.join(@fixtures, "valid.json")
    assert {:ok, record} = AgentSource.resolve(path, startup_cwd: @fixtures)

    assert record.kind == :file
    assert record.identity.path == path
    assert record.digest == Digest.portable(File.read!(path))
    assert record.label == "valid.json"
    assert is_map(record.identity)
    refute record.digest == "sha256:forged"
    refute record.label == "Forged Jido"
  end
end
