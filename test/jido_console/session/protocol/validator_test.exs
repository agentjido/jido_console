defmodule Jido.Console.Session.Protocol.ValidatorTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Continuity, Protocol}
  alias Jido.Console.Session.Protocol.{Generated, Generator, Validator}

  test "generated Elixir and TypeScript types stay synchronized with the schema" do
    {:ok, schema} = Protocol.schema()
    digest = Generator.digest()
    assert Generated.digest() == digest
    assert Generated.catalog()["digest"] == digest
    assert Enum.sort(Generated.families()) == Enum.sort(Protocol.families())

    Enum.each(Protocol.families(), fn family ->
      {:ok, types} = Protocol.types(schema, family)
      assert Generated.types(family) == types
    end)

    input_admitted = get_in(Generated.catalog(), ["families", "event", "types", "input_admitted"])

    assert input_admitted == %{
             "known_fields" =>
               ~w(client_id durability identities input_id items origin queue sensitivity sequence trust),
             "locality" => "shared",
             "required_fields" => ~w(durability identities origin sensitivity sequence trust)
           }

    typescript = File.read!(Path.join(Path.dirname(Protocol.schema_path()), "generated.ts"))
    assert typescript =~ "export const protocolDigest = #{inspect(digest)}"
    assert typescript =~ "export type CommandType"
    assert typescript =~ "export type ControlType"
    assert typescript =~ "export interface EventInputAdmittedEnvelope"
    assert typescript =~ ~s(family: "event";)
    assert typescript =~ ~s(type: "input_admitted";)
    assert typescript =~ ~s("sequence": unknown;)
    assert typescript =~ ~s("input_id"?: unknown;)
    assert typescript =~ "export type ProtocolEnvelope ="
    assert typescript =~ "knownType("
  end

  test "drift is detected when generated output does not match the schema" do
    assert Generated.digest() == Generator.digest()

    stale = Map.put(Generated.catalog(), "digest", "0")
    refute stale["digest"] == Generator.digest()
  end

  test "the example corpus validates through generated Elixir types" do
    examples = Path.wildcard(Path.join(Path.dirname(Protocol.schema_path()), "examples/*.json"))
    assert examples != []

    Enum.each(examples, fn path ->
      assert {:ok, validated} = path |> File.read!() |> Validator.validate_json()
      assert validated["protocol"] == "jido.session"
    end)
  end

  test "invalid versions, types, and oversized values fail with stable errors" do
    assert {:error, {:incompatible_protocol_version, "2"}} =
             Validator.validate(envelope(%{"version" => "2"}))

    assert {:error, {:unknown_protocol_type, "command", "explode"}} =
             Validator.validate(envelope(%{"type" => "explode"}))

    oversized = String.duplicate("a", 200_001)

    assert {:error, {:oversized_protocol_value, 200_001, 200_000}} =
             Validator.validate(envelope(%{"payload" => %{"text" => oversized}}))

    assert {:error, :invalid_protocol_shape} = Validator.validate(["not", "an", "object"])
  end

  test "required and sibling type fields use the exact generated contract" do
    input_admitted = event_envelope("input_admitted", %{"input_id" => "inp_1", "client_id" => "cli_1"})

    assert {:error, {:missing_protocol_fields, "event", "input_admitted", ["sequence"]}} =
             input_admitted
             |> update_in(["payload"], &Map.delete(&1, "sequence"))
             |> Validator.validate()

    assert {:error, {:unexpected_protocol_fields, "event", "input_admitted", ["run_id"]}} =
             input_admitted
             |> put_in(["payload", "run_id"], "run_1")
             |> Validator.validate()

    assert {:error, {:unexpected_protocol_fields, "command", "request_snapshot", ["text"]}} =
             envelope(%{"type" => "request_snapshot", "payload" => %{"client_id" => "cli_1", "text" => "wrong"}})
             |> Validator.validate()
  end

  test "bounded unknown data is retained and cannot grant authority" do
    assert {:ok, validated} =
             Validator.validate(
               envelope(%{
                 "payload" => %{"text" => "hello", "note" => "bounded extra"}
               })
             )

    assert validated["payload"]["note"] == "bounded extra"

    assert {:error, {:unknown_authority_field, ["permission"]}} =
             Validator.validate(envelope(%{"payload" => %{"text" => "hello", "permission" => "admin"}}))

    huge_unknown = %{"blob" => String.duplicate("x", 5000)}

    assert {:error, :unknown_data_overflow} =
             Validator.validate(envelope(%{"payload" => Map.merge(%{"text" => "hello"}, huge_unknown)}))
  end

  test "generated TypeScript catalog rejects the same invalid fixtures" do
    catalog = Generated.catalog()
    assert catalog["version"] == "1"
    assert catalog["authority"]["never_grant_from"] -- ["renderer", "transport", "host", "origin"] == ["unknown"]

    assert Validator.validate(envelope(%{"family" => "control", "type" => "attach"})) ==
             Validator.validate(envelope(%{"family" => "control", "type" => "attach"}), catalog: catalog)
  end

  test "rejects invalid envelopes, payload shapes, local fields, and collection bounds" do
    assert {:error, :invalid_protocol_envelope} = Validator.validate(%{})
    assert {:error, {:invalid_protocol_name, "other"}} = Validator.validate(envelope(%{"protocol" => "other"}))
    assert {:error, {:invalid_protocol_json, _reason}} = Validator.validate_json("{")
    assert {:error, :invalid_protocol_payload} = Validator.validate(envelope(%{"payload" => []}))

    catalog = Generated.catalog()
    [local_field | _rest] = catalog["client_local_fields"]

    assert {:error, :client_local_forbidden} =
             Validator.validate(envelope(%{"payload" => %{"text" => "hello", local_field => true}}))

    bounds = catalog["bounds"]

    oversized_list = Enum.to_list(0..bounds["max_list_items"])

    assert {:error, :oversized_protocol_list} =
             Validator.validate(envelope(%{"payload" => %{"text" => oversized_list}}))

    oversized_map = Map.new(0..bounds["max_map_keys"], &{Integer.to_string(&1), &1})
    assert {:error, :oversized_protocol_map} = Validator.validate(envelope(%{"payload" => %{"text" => oversized_map}}))

    too_many_unknown =
      0..bounds["max_unknown_keys"]
      |> Map.new(&{"unknown_#{&1}", &1})
      |> Map.put("text", "hello")

    assert {:error, :unknown_data_overflow} = Validator.validate(envelope(%{"payload" => too_many_unknown}))

    assert {:error, {:forbidden_runtime_value, :function}} =
             Validator.validate(envelope(%{"payload" => %{"text" => "hello", "callback" => fn -> :ok end}}))
  end

  test "durable protocol families expose separate generated result contracts" do
    assert Generated.types("receipt") ==
             ~w(client_output command console_event effect_result effect_start input jidoka_checkpoint watermark)

    assert Generated.types("generation") == ~w(claim fenced_operation)
    assert Generated.types("watermark") == ["console_jidoka"]
    assert Generated.types("recovery") == ~w(continuity_mode session_state store_state)

    assert Generated.types("operation") ==
             ~w(abandon exact_resume fork repair retry transcript_only_resume)

    assert Generated.types("rejection") ==
             ~w(sensitive_result_blocked sensitive_value_rejected)

    exact = get_in(Generated.catalog(), ["families", "operation", "types", "exact_resume"])
    transcript = get_in(Generated.catalog(), ["families", "operation", "types", "transcript_only_resume"])
    retry = get_in(Generated.catalog(), ["families", "operation", "types", "retry"])

    assert exact["field_values"]["watermark_required"] == ["yes"]
    assert transcript["field_values"]["mode"] == ["transcript_only"]
    assert retry["field_values"]["calls_model_or_tool"] == [true]
  end

  test "canonical durable fixtures validate through generated contracts" do
    root = Path.dirname(Protocol.schema_path())

    for name <- ~w(
          receipt.input.json
          generation.claim.json
          watermark.console_jidoka.json
          recovery.session_state.json
          operation.exact_resume.json
          rejection.sensitive_value_rejected.json
        ) do
      assert {:ok, validated} =
               root
               |> Path.join("examples/#{name}")
               |> File.read!()
               |> Validator.validate_json()

      assert validated["protocol"] == "jido.session"
    end
  end

  test "fixed values reject an invalid continuity mode and watermark state" do
    assert {:error, {:invalid_protocol_field_value, "recovery", "continuity_mode", "mode"}} =
             protocol_envelope("recovery", "continuity_mode", %{
               "mode" => "silent_downgrade",
               "ready" => false,
               "execution_authority" => "none",
               "watermark_id" => nil
             })
             |> Validator.validate()

    assert {:error, {:invalid_protocol_field_value, "watermark", "console_jidoka", "state"}} =
             watermark_envelope("implicitly_verified")
             |> Validator.validate()
  end

  test "structural credential canaries fail with bounded redacted results" do
    path =
      Continuity.schema_path()
      |> Path.dirname()
      |> Path.join("rejection-fixtures.v1.json")

    fixtures = path |> File.read!() |> Jason.decode!()
    assert fixtures["canary"] == "CANARY_DO_NOT_STORE"

    transition = Enum.find(fixtures["generated_cases"], &(&1["name"] == "invalid_watermark_transition"))
    assert {:ok, contract} = Continuity.schema()

    assert {:error, {:invalid_watermark_transition, "reserved", "verified"}} =
             Continuity.validate_watermark_transition(contract, transition["from"], transition["to"])

    Enum.each(fixtures["cases"], fn fixture ->
      assert {:error, {:sensitive_value_rejected, surface, details}} =
               Validator.validate(fixture["envelope"])

      assert is_binary(surface) and surface != ""
      assert details["redacted"] == true
      refute inspect({surface, details}) =~ fixtures["canary"]
    end)

    assert {:ok, _value} =
             Validator.validate(
               envelope(%{
                 "payload" => %{
                   "text" => "A normal prompt can name ${SERVICE_TOKEN} without secret resolution.",
                   "credential_profile_id" => "profile_fixture"
                 }
               })
             )
  end

  test "final-call containment blocks a materialized value without returning it" do
    canary = "MATERIALIZED_CANARY_VALUE"

    value =
      protocol_envelope("outcome", "completed", %{
        "ref_id" => "run_fixture",
        "content" => "provider returned #{canary}",
        "view" => %{}
      })

    assert {:error, {:sensitive_result_blocked, :final_boundary, details}} =
             Validator.validate_final_boundary(value, [canary])

    assert details["redacted"] == true
    assert details["path"] == "payload.content"
    refute inspect(details) =~ canary
    assert {:ok, ^value} = Validator.validate_final_boundary(value, ["different value"])
  end

  test "PID, reference, port, function, struct, and non-string keys cannot enter generated values" do
    port = Port.open({:spawn, "true"}, [])

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    assert_runtime_rejection(self(), :pid)
    assert_runtime_rejection(make_ref(), :reference)
    assert_runtime_rejection(port, :port)
    assert_runtime_rejection(fn -> :ok end, :function)

    assert {:error, {:forbidden_runtime_value, :struct}} =
             Validator.validate(envelope(%{"payload" => %{"text" => %URI{host: "example.test"}}}))

    assert {:error, :non_string_protocol_key} =
             Validator.validate(envelope(%{"payload" => %{"text" => %{:atom_key => true}}}))
  end

  test "rejection details keep their exact encoded bound" do
    oversized = String.duplicate("x", 65_536)

    value =
      protocol_envelope("rejection", "sensitive_value_rejected", %{
        "operation_id" => "op_fixture",
        "phase" => "before_persistence",
        "surface" => "metadata",
        "reason" => "fixture",
        "redacted_details" => oversized
      })

    assert {:error, :oversized_protocol_payload} = Validator.validate(value)
  end

  defp envelope(overrides) do
    %{
      "protocol" => "jido.session",
      "version" => "1",
      "family" => "command",
      "type" => "submit_input",
      "id" => "plt_command_test",
      "payload" => %{"text" => "hello"}
    }
    |> Map.merge(overrides)
  end

  defp event_envelope(type, fields) do
    envelope(%{
      "family" => "event",
      "type" => type,
      "payload" =>
        Map.merge(
          %{
            "sequence" => 1,
            "durability" => "process",
            "sensitivity" => "public",
            "origin" => %{"kind" => "session", "actor_id" => "ses_1"},
            "trust" => %{"evidence" => "test", "policy" => "session-owner"},
            "identities" => [%{"kind" => "session", "id" => "ses_1", "session_id" => "ses_1"}]
          },
          fields
        )
    })
  end

  defp protocol_envelope(family, type, payload) do
    envelope(%{"family" => family, "type" => type, "payload" => payload})
  end

  defp watermark_envelope(state) do
    protocol_envelope("watermark", "console_jidoka", %{
      "watermark_id" => "wm_fixture",
      "generation" => 2,
      "console_sequence" => 4,
      "console_event_id" => "evt_fixture",
      "console_chain_digest" => "sha256:console",
      "jidoka_session_id" => "jidoka_fixture",
      "jidoka_revision" => 3,
      "jidoka_snapshot_id" => "snapshot_fixture",
      "jidoka_value_digest" => "sha256:jidoka",
      "jidoka_request_id" => "request_fixture",
      "jidoka_lease_id" => "lease_fixture",
      "protocol_version" => "1",
      "durable_schema_version" => "1",
      "state" => state
    })
  end

  defp assert_runtime_rejection(runtime_value, kind) do
    assert {:error, {:forbidden_runtime_value, ^kind}} =
             Validator.validate(envelope(%{"payload" => %{"text" => runtime_value}}))
  end
end
