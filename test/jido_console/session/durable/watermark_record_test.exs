defmodule Jido.Console.Session.Durable.WatermarkRecordTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Durable.WatermarkRecord

  @digest "sha256:" <> String.duplicate("a", 64)

  test "declares the closed state machine and rejects identity drift" do
    assert WatermarkRecord.states() ==
             ~w(reserved jidoka_committed console_committed verified repair_required abandoned)

    assert :ok = WatermarkRecord.validate_transition(nil, "reserved")
    assert :ok = WatermarkRecord.validate_transition("reserved", "jidoka_committed")
    assert :ok = WatermarkRecord.validate_transition("jidoka_committed", "console_committed")
    assert :ok = WatermarkRecord.validate_transition("console_committed", "verified")
    assert :ok = WatermarkRecord.validate_transition("repair_required", "console_committed")
    assert :ok = WatermarkRecord.validate_transition("repair_required", "abandoned")

    assert {:error, {:invalid_watermark_transition, "reserved", "verified"}} =
             WatermarkRecord.validate_transition("reserved", "verified")

    assert {:error, {:invalid_watermark_transition, "verified", "repair_required"}} =
             WatermarkRecord.validate_transition("verified", "repair_required")

    assert :ok = WatermarkRecord.validate(payload())

    assert {:error, :watermark_identity_mismatch} =
             payload()
             |> put_in(["jidoka_identity", "session_id"], "other-session")
             |> WatermarkRecord.validate()

    assert {:error, {:invalid_watermark_state, "implicit"}} =
             payload() |> Map.put("state", "implicit") |> WatermarkRecord.validate()
  end

  defp payload do
    %{
      "watermark_id" => "watermark-test",
      "console_identity" => %{
        "session_id" => "session-test",
        "generation" => 1,
        "sequence" => 1,
        "event_id" => "event-test",
        "operation_id" => "console-operation",
        "chain_digest" => @digest
      },
      "console_digest" => @digest,
      "jidoka_identity" => %{
        "session_id" => "session-test",
        "revision" => 2,
        "request_id" => "request-test",
        "lease_id" => "lease-test",
        "snapshot_id" => "snapshot-test",
        "operation_id" => "jidoka-operation",
        "value_digest" => @digest
      },
      "jidoka_digest" => @digest,
      "state" => "reserved"
    }
  end
end
