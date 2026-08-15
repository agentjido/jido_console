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

  defp sibling(name) do
    Protocol.schema_path() |> Path.dirname() |> Path.join(name)
  end
end
