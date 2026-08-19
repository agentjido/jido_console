defmodule Jido.Console.Session.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Envelope

  test "builds one typed envelope without a generated catalog" do
    assert {:ok, envelope} =
             Envelope.new("event", "input_admitted", %{
               "id" => "event-1",
               "session_id" => "session-1",
               "sequence" => 1
             })

    assert %Envelope{
             family: "event",
             type: "input_admitted",
             id: "event-1",
             session_id: "session-1",
             payload: %{"sequence" => 1}
           } = envelope

    assert envelope["type"] == "input_admitted"
    assert get_in(envelope, ["payload", "sequence"]) == 1
    assert {:ok, ^envelope} = Envelope.validate(envelope)
  end

  test "normalizes portable maps to structs" do
    map = %{
      "family" => "receipt",
      "type" => "input",
      "id" => "receipt-1",
      "session_id" => "session-1",
      "payload" => %{"status" => "committed"}
    }

    assert {:ok, %Envelope{} = envelope} = Envelope.validate(map)
    assert Envelope.to_map(envelope) == map
  end

  test "accepts only the three live envelope families" do
    assert {:error, :invalid_session_envelope} = Envelope.new("command", "submit_input", %{})
    assert {:error, :invalid_session_envelope} = Envelope.validate(%{})
  end

  test "rejects client-local, credential, runtime, and oversized values" do
    assert {:error, {:sensitive_value_rejected, local}} =
             Envelope.new("event", "input_admitted", %{"draft" => "unsent"})

    assert local["redacted"] == true

    assert {:error, {:sensitive_value_rejected, secret}} =
             Envelope.new("receipt", "input", %{"authorization" => "hidden"})

    assert secret["redacted"] == true

    assert {:error, {:sensitive_value_rejected, runtime}} =
             Envelope.new("event", "input_admitted", %{"callback" => fn -> :ok end})

    assert runtime["redacted"] == true

    oversized = String.duplicate("a", Envelope.limits()["max_text_bytes"] + 1)

    assert {:error, {:oversized_session_value, _, _}} =
             Envelope.new("event", "input_admitted", %{"text" => oversized})
  end

  test "blocks a materialized value at the final boundary" do
    canary = "MATERIALIZED_CANARY_VALUE"

    assert {:ok, envelope} =
             Envelope.new("delivery", "output_batch", %{
               "content" => "provider returned #{canary}"
             })

    assert {:error, {:sensitive_result_blocked, :final_boundary, details}} =
             Envelope.validate_final_boundary(envelope, [canary])

    assert details == %{
             "path" => "payload.content",
             "reason" => "materialized_value",
             "redacted" => true
           }
  end
end
