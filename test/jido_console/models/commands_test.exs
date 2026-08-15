defmodule Jido.Console.Models.CommandsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models.Commands

  test "list shows only declared catalog identities and tiers" do
    assert {:ok, output} = Commands.list()
    assert output =~ "PROVIDER\tMODEL\tTIER\tEVIDENCE"
    assert output =~ "openai\tgpt-4.1-mini\tsupported\tharness:openai:gpt-4.1-mini"
    assert output =~ "ollama\tllama3.2\tbeta\tpending:ollama-beta"
    refute output =~ "sk-"
  end

  test "show reports exact support data for one model" do
    assert {:ok, output} = Commands.show("openai", "gpt-4.1-mini")
    assert output =~ "identity: openai:gpt-4.1-mini"
    assert output =~ "tier: supported"
    assert output =~ "capability.streaming: supported"
    assert output =~ "cancellation: supported"
    assert output =~ "known_gaps:"
    refute output =~ "sk-"

    assert {:ok, same} = Commands.show("openai:gpt-4.1-mini")
    assert same == output
  end

  test "test reports recorded contract success" do
    assert {:ok, output} = Commands.test("openai", "gpt-4.1-mini")
    assert output =~ "identity: openai:gpt-4.1-mini"
    assert output =~ "source: recorded"
    assert output =~ "contract.streaming: pass"
    refute output =~ "sk-"
  end

  test "offline test denies a provider network call" do
    assert {:error, {:offline_denied, output}} = Commands.test("openai", "gpt-4.1-mini", offline: true)
    assert output =~ "offline: deny"
    refute output =~ "sk-"
  end

  test "required unsupported capability fails before the turn" do
    assert {:error, {:capability_denied, output}} =
             Commands.test("ollama", "llama3.2", require: "streaming")

    assert output =~ "preflight: deny"
    assert output =~ "streaming"
  end

  test "unknown models stay usage failures" do
    assert {:error, {:unknown_model, "openai:missing"}} = Commands.show("openai", "missing")
    assert {:error, :invalid_model_identity} = Commands.show("not-an-identity")
  end
end
