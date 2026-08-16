defmodule Jido.Console.Session.ProtocolTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Protocol

  setup do
    assert {:ok, schema} = Protocol.schema()
    %{schema: schema}
  end

  test "the schema defines every required family with a version and compatibility rule", %{schema: schema} do
    assert :ok = Protocol.review(schema)
    assert {:ok, %{protocol: "jido.session", version: "1"}} = Protocol.identity(schema)

    Enum.each(Protocol.families(), fn family ->
      assert {:ok, %{"version" => "1", "compatibility" => "additive"}} =
               Protocol.compatibility(schema, family)

      assert {:ok, types} = Protocol.types(schema, family)
      assert types != []

      Enum.each(types, fn name ->
        assert {:ok, locality} = Protocol.locality(schema, family, name)
        assert locality in ["shared", "client_local"]
      end)
    end)
  end

  test "protocol data has a JSON-compatible representation", %{schema: schema} do
    assert {:ok, envelope} =
             Protocol.envelope(schema, "command", "submit_input", %{
               "id" => "plt_command_fixture",
               "session_id" => "ses_fixture",
               "text" => "Hello"
             })

    assert {:ok, json} = Protocol.encode(envelope)
    assert {:ok, decoded} = Protocol.decode(json)
    assert decoded["protocol"] == "jido.session"
    assert decoded["family"] == "command"
    assert decoded["type"] == "submit_input"
    assert decoded["payload"]["text"] == "Hello"

    examples = Path.wildcard(Path.join(Path.dirname(Protocol.schema_path()), "examples/*.json"))
    assert length(examples) >= 6

    Enum.each(examples, fn path ->
      assert {:ok, example} = path |> File.read!() |> Protocol.decode()
      assert {:ok, _encoded} = Protocol.encode(example)
      assert {:ok, _declaration} = Protocol.type(schema, example["family"], example["type"])
    end)
  end

  test "client-local input and navigation cannot enter shared session state", %{schema: schema} do
    assert Protocol.shared?(schema, "command", "submit_input")
    refute Protocol.shared?(schema, "interaction", "draft_changed")
    refute Protocol.shared?(schema, "interaction", "cursor_moved")
    refute Protocol.shared?(schema, "interaction", "viewport_changed")
    refute Protocol.shared?(schema, "interaction", "key_local")

    assert {:error, {:client_local_forbidden, "command", "submit_input"}} =
             Protocol.envelope(schema, "command", "submit_input", %{"draft" => "unsent text"})

    assert {:error, {:client_local_forbidden, "event", "input_admitted"}} =
             Protocol.envelope(schema, "event", "input_admitted", %{"cursor" => 3})

    locality =
      "locality-decision.json"
      |> sibling()
      |> File.read!()
      |> Jason.decode!()

    assert Enum.sort(locality["client_local"]["cannot_enter_shared_state"]) ==
             Enum.sort(Protocol.client_local_fields(schema))
  end

  test "the schema defines bounds and rejects authority from renderer, transport, host, or origin", %{
    schema: schema
  } do
    assert {:ok, bounds} = Protocol.bounds(schema)
    assert bounds["max_unknown_bytes"] > 0
    assert bounds["max_text_bytes"] >= bounds["max_string_bytes"]

    assert Enum.sort(Protocol.never_grant_from(schema)) ==
             Enum.sort(["renderer", "transport", "host", "origin", "unknown"])

    refute Protocol.authority_field?(schema, "origin")
    refute Protocol.authority_field?(schema, "host")
    refute Protocol.authority_field?(schema, "transport")
    refute Protocol.authority_field?(schema, "renderer")

    assert {:error, {:authority_from_forbidden, "origin"}} =
             Protocol.envelope(schema, "control", "attach", %{"authority_from" => "origin"})

    assert {:error, {:authority_from_forbidden, "transport"}} =
             Protocol.envelope(schema, "command", "invoke_command", %{"authority_from" => "transport"})
  end

  test "schema and JSON failures have stable results" do
    invalid = Path.join(System.tmp_dir!(), "jido-protocol-invalid-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(invalid) end)
    File.write!(invalid, "{")

    assert {:error, {:protocol_schema_invalid, message}} = Protocol.schema(path: invalid)
    assert is_binary(message)
    assert {:error, {:protocol_schema_unreadable, :enoent}} = Protocol.schema(path: invalid <> ".missing")

    assert {:error, :protocol_json_not_object} = Protocol.decode("[]")
    assert {:error, {:protocol_json_invalid, %Jason.DecodeError{}}} = Protocol.decode("{")
    assert {:error, error} = Protocol.encode(%{"pid" => self()})
    assert error.__struct__ == Elixir.Protocol.UndefinedError
  end

  test "missing and invalid declarations are reported without exceptions", %{schema: schema} do
    assert {:ok, %{"rule" => "additive"}} = Protocol.compatibility(schema, :protocol)
    assert {:error, :protocol_identity_missing} = Protocol.identity(%{})
    assert {:error, :protocol_compatibility_missing} = Protocol.compatibility(%{}, :protocol)

    assert {:error, {:unknown_protocol_family, "missing"}} =
             Protocol.compatibility(schema, "missing")

    assert {:error, {:unknown_protocol_type, "command", "missing"}} =
             Protocol.type(schema, "command", "missing")

    missing_types = %{"families" => %{"command" => %{}}}
    assert {:error, :protocol_types_missing} = Protocol.types(missing_types, "command")
    assert {:error, {:unknown_protocol_family, "event"}} = Protocol.types(%{}, "event")

    invalid_locality = put_in(schema, ["families", "command", "types", "submit_input", "locality"], "remote")

    assert {:error, {:protocol_locality_missing, "command", "submit_input"}} =
             Protocol.locality(invalid_locality, "command", "submit_input")

    assert Protocol.client_local_fields(%{}) == []
    assert {:error, :protocol_bounds_missing} = Protocol.bounds(%{})
    assert {:error, :protocol_authority_missing} = Protocol.authority(%{})
    refute Protocol.authority_field?(%{}, "permission")
    assert Protocol.never_grant_from(%{}) == []

    assert {:ok, envelope} = Protocol.envelope(schema, "interaction", "draft_changed")
    assert envelope["id"] =~ "plt_interaction_"

    assert {:error, defects} = Protocol.review(%{})
    assert :protocol_identity_missing in defects
    assert :protocol_bounds_missing in defects
    assert :protocol_authority_missing in defects
    assert {:unknown_protocol_family, "command"} in defects

    malformed =
      schema
      |> put_in(["families", "command", "version"], nil)
      |> put_in(["families", "command", "compatibility"], "breaking")
      |> put_in(["families", "command", "types"], %{
        "invalid" => "not a declaration",
        "incomplete" => %{"locality" => "remote"}
      })
      |> put_in(["families", "event"], %{})
      |> put_in(["bounds"], %{})
      |> put_in(["authority"], %{"never_grant_from" => ["renderer"]})

    assert {:error, defects} = Protocol.review(malformed)
    assert {:family_version_missing, "command"} in defects
    assert {:type_invalid, "command", "invalid"} in defects
    assert {:type_incomplete, "command", "incomplete", ["fields"]} in defects
    assert {:type_locality_invalid, "command", "incomplete"} in defects
    assert :protocol_types_missing in defects
    assert {:bounds_incomplete, _missing} = Enum.find(defects, &match?({:bounds_incomplete, _}, &1))

    assert {:authority_denial_incomplete, _missing} =
             Enum.find(defects, &match?({:authority_denial_incomplete, _}, &1))
  end

  defp sibling(name) do
    Protocol.schema_path() |> Path.dirname() |> Path.join(name)
  end
end
