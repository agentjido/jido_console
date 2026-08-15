defmodule Jido.Console.Session.EffectTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Effect

  test "every command result has a distinct typed effect" do
    for outcome <- Effect.outcomes() do
      assert {:ok, effect} =
               Effect.new(
                 outcome: outcome,
                 command_id: "cmd_help",
                 session_id: "ses_1",
                 provenance: %{source: "builtin"}
               )

      envelope = Effect.to_protocol(effect)
      assert envelope["type"] == Atom.to_string(outcome)
      assert envelope["command_id"] == "cmd_help"
      assert {:ok, _} = Jason.encode(envelope)
    end
  end

  test "unknown effect data cannot grant authority" do
    assert {:error, {:unknown_authority_field, ["permission"]}} =
             Effect.new(outcome: :accepted, command_id: "cmd_help", session_id: "ses_1", data: %{"permission" => "all"})

    assert {:error, :invalid_effect_outcome} =
             Effect.new(outcome: :explode, command_id: "cmd_help", session_id: "ses_1")
  end
end
