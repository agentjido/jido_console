defmodule Jido.Console.AgentSource.AdmissionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.AgentSource.Admission

  @valid_json ~S({"agent":{"id":"safe_agent","instructions":"Safe.","model":"openai:gpt-4.1-mini"}})
  @valid_yaml "agent:\n  id: safe_agent\n  instructions: Safe.\n  model: openai:gpt-4.1-mini\n"

  test "accepts behavior fields and leaves the execution policy request inert" do
    document = ~S({
      "version": 1,
      "agent": {
        "id": "behavior_agent",
        "instructions": "Behave safely.",
        "model": "openai:gpt-4.1-mini",
        "generation": {"temperature": 0.2},
        "execution_profile": "coding.trusted-workspace",
        "memory": {"enabled": true, "capture": "conversation", "inject": "context", "max_entries": 3}
      },
      "runtime_defaults": {"max_model_turns": 4, "timeout_ms": 10000},
      "metadata": {"owner": "fixture"}
    })

    assert {:ok, %Jidoka.Agent.Spec{} = spec} = Admission.admit(document, :json)
    assert spec.id == "behavior_agent"
    assert spec.execution_profile == "coding.trusted-workspace"
    assert spec.operations == []
    assert spec.extensions == []
    assert spec.runtime_defaults == %{"max_model_turns" => 4, "timeout_ms" => 10_000}
    assert spec.memory.capture == :conversation
    assert spec.memory.inject == :context
  end

  test "rejects duplicate JSON and YAML keys at all depths" do
    documents = [
      {:json, ~S({"agent":{"id":"one","id":"one","model":"openai:gpt-4.1-mini"}})},
      {:json, ~S({"agent":{"id":"one","model":{"provider":"openai","id":"gpt-4.1-mini","id":"gpt-4.1-mini"}}})},
      {:yaml, "agent:\n  id: one\n  id: one\n  model: openai:gpt-4.1-mini\n"},
      {:yaml, "agent:\n  id: one\n  model:\n    provider: openai\n    id: gpt-4.1-mini\n    id: gpt-4.1-mini\n"}
    ]

    for {format, document} <- documents do
      assert {:error, {:duplicate_key, ^format}} = Admission.admit(document, format)
    end
  end

  test "rejects YAML anchors, aliases, merge keys, and custom tags before import" do
    documents = [
      "agent: &agent\n  id: safe_agent\n  model: openai:gpt-4.1-mini\n",
      "base: &base\n  id: safe_agent\nagent: *base\n",
      "base: &base\n  id: safe_agent\n  model: openai:gpt-4.1-mini\nagent:\n  <<: *base\n",
      "agent: !unsafe\n  id: safe_agent\n  model: openai:gpt-4.1-mini\n",
      "agent:\n  id: safe_agent\n  model: openai:gpt-4.1-mini\n  metadata:\n    nested: &nested [x]\n    value: *nested\n"
    ]

    for document <- documents do
      assert {:error, {:forbidden_yaml_syntax, _kind}} = Admission.admit(document, :yaml)
    end
  end

  test "forces the requested parser and does not sniff content" do
    assert {:error, {:invalid_syntax, :json}} = Admission.admit(@valid_yaml, :json)
    assert {:ok, %Jidoka.Agent.Spec{id: "safe_agent"}} = Admission.admit(@valid_json, :yaml)
  end

  test "rejects capability and authority fields, including nested forms" do
    fields =
      ~w(
        tools operations extensions controls operation_controls
        context context_schema context_schema_registry
        result result_schema result_schema_registry
        registries operation_registry extension_registry control_registry
        adapter coding_pack security_profile registration workspace_root consent
      )

    test_pid = self()

    for field <- fields do
      before_import = fn _bytes, _format -> send(test_pid, {:import_reached, field}) end

      document =
        Jason.encode!(%{
          "agent" => %{"id" => "unsafe_agent", "model" => "openai:gpt-4.1-mini"},
          field => %{}
        })

      assert {:error, {:forbidden_agent_field, ^field}} =
               Admission.admit(document, :json, before_import: before_import)

      nested =
        Jason.encode!(%{
          "agent" => %{
            "id" => "unsafe_agent",
            "model" => "openai:gpt-4.1-mini",
            "generation" => %{"provider_options" => %{field => %{}}}
          }
        })

      assert {:error, {:forbidden_agent_field, ^field}} =
               Admission.admit(nested, :json, before_import: before_import)

      refute_received {:import_reached, ^field}
    end
  end

  test "rejects unknown turn defaults and shared memory routes" do
    unknown_default =
      Jason.encode!(%{
        "agent" => %{"id" => "unsafe_agent", "model" => "openai:gpt-4.1-mini"},
        "runtime_defaults" => %{"max_model_turns" => 3, "operation_timeout_ms" => 1}
      })

    shared_memory =
      Jason.encode!(%{
        "agent" => %{
          "id" => "unsafe_agent",
          "model" => "openai:gpt-4.1-mini",
          "memory" => %{"scope" => "agent", "namespace" => "shared"}
        }
      })

    assert {:error, {:forbidden_agent_field, "operation_timeout_ms"}} =
             Admission.admit(unknown_default, :json)

    assert {:error, {:forbidden_agent_field, field}} = Admission.admit(shared_memory, :json)
    assert field in ["scope", "namespace"]
  end

  test "applies the Jidoka depth and node limits" do
    deep_metadata =
      Enum.reduce(1..70, %{"value" => "deep"}, fn index, value ->
        %{Integer.to_string(index) => value}
      end)

    deep = %{
      "agent" => %{"id" => "deep", "model" => "openai:gpt-4.1-mini"},
      "metadata" => deep_metadata
    }

    many = %{
      "agent" => %{"id" => "many", "model" => "openai:gpt-4.1-mini"},
      "metadata" => %{"nodes" => Enum.to_list(1..20_001)}
    }

    assert {:error, {:import_limit, :depth}} = Admission.admit(Jason.encode!(deep), :json)
    assert {:error, {:import_limit, :nodes}} = Admission.admit(Jason.encode!(many), :json)
  end

  test "calls the import boundary only after syntax and capability admission" do
    test_pid = self()
    before_import = fn bytes, format -> send(test_pid, {:before_import, bytes, format}) end

    assert {:ok, %Jidoka.Agent.Spec{}} =
             Admission.admit(@valid_json, :json, before_import: before_import)

    assert_receive {:before_import, @valid_json, :json}

    duplicate = ~S({"agent":{"id":"one","id":"two","model":"openai:gpt-4.1-mini"}})

    assert {:error, {:duplicate_key, :json}} =
             Admission.admit(duplicate, :json, before_import: before_import)

    refute_receive {:before_import, ^duplicate, :json}

    tools = ~S({"agent":{"id":"unsafe","model":"openai:gpt-4.1-mini"},"tools":{}})

    assert {:error, {:forbidden_agent_field, "tools"}} =
             Admission.admit(tools, :json, before_import: before_import)

    refute_receive {:before_import, ^tools, :json}
  end

  test "rejects invalid admission arguments and document shapes" do
    assert {:error, :invalid_agent_source_admission} = Admission.admit(:invalid, :json)
    assert {:error, :invalid_agent_source_admission} = Admission.admit("{}", :toml)
    assert {:error, :invalid_agent_source_admission} = Admission.admit("{}", :json, :invalid)

    assert {:error, {:forbidden_agent_field, "document"}} =
             Admission.admit(~S([{"id":"not-a-document"}]), :json)

    assert {:error, {:forbidden_agent_field, "agent"}} =
             Admission.admit(~S({"agent":"not-an-object"}), :json)
  end

  test "validates flat documents, memory, runtime defaults, and callbacks" do
    assert {:ok, %Jidoka.Agent.Spec{id: "flat_agent"}} =
             Admission.admit(
               ~S({"id":"flat_agent","model":"openai:gpt-4.1-mini","memory":true}),
               :json
             )

    assert {:error, {:forbidden_agent_field, "memory"}} =
             Admission.admit(
               ~S({"id":"flat_agent","model":"openai:gpt-4.1-mini","memory":"shared"}),
               :json
             )

    assert {:error, {:forbidden_agent_field, "runtime_defaults"}} =
             Admission.admit(
               ~S({"id":"flat_agent","model":"openai:gpt-4.1-mini","runtime_defaults":[]}),
               :json
             )

    assert {:error, :invalid_agent_source_admission_callback} =
             Admission.admit(@valid_json, :json, before_import: :invalid)
  end

  test "rejects malformed, multiple, and nested duplicate YAML or JSON data" do
    assert {:error, {:invalid_syntax, :yaml}} = Admission.admit("agent: [", :yaml)

    assert {:error, {:forbidden_yaml_syntax, :multiple_documents}} =
             Admission.admit("---\nagent:\n  id: one\n---\nagent:\n  id: two\n", :yaml)

    nested_duplicate =
      ~S({"agent":{"id":"one","model":"openai:gpt-4.1-mini","metadata":[{"ok":true},{"x":1,"x":2}]}})

    assert {:error, {:duplicate_key, :json}} = Admission.admit(nested_duplicate, :json)

    nested_yaml_duplicate =
      "agent:\n  id: one\n  model: openai:gpt-4.1-mini\n  metadata:\n    - ok: true\n    - duplicate: 1\n      duplicate: 2\n"

    assert {:error, {:duplicate_key, :yaml}} = Admission.admit(nested_yaml_duplicate, :yaml)
  end

  test "applies the byte limit at the Jidoka import boundary" do
    prefix = ~S({"id":"large","model":"openai:gpt-4.1-mini","instructions":")
    suffix = ~S("})
    document = prefix <> String.duplicate("x", 1_000_001 - byte_size(prefix) - byte_size(suffix)) <> suffix

    assert byte_size(document) == 1_000_001
    assert {:error, {:import_limit, :bytes}} = Admission.admit(document, :json)
  end
end
