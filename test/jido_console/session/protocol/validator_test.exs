defmodule Jido.Console.Session.Protocol.ValidatorTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Protocol
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
             "known_fields" => ~w(client_id durability identities input_id origin sensitivity sequence trust),
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

    assert {:error, :unknown_data_overflow} =
             Validator.validate(envelope(%{"payload" => %{"text" => "hello", "callback" => fn -> :ok end}}))
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
end
