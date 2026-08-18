defmodule Jido.Console.Session.Durable.RecordTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Durable.{Catalog, Record}

  @digest "sha256:" <> String.duplicate("a", 64)
  @field_values %{
    "string" => "fixture",
    "string_or_null" => "fixture",
    "integer" => 1,
    "integer_or_null" => 1,
    "boolean" => true,
    "map" => %{},
    "map_or_null" => %{},
    "list" => [],
    "digest" => @digest,
    "digest_or_genesis" => @digest,
    "digest_or_null" => @digest,
    "json" => %{}
  }

  test "all authoritative record types have strict bounded round trips" do
    for {type, index} <- Enum.with_index(Catalog.record_types()) do
      record = record(type, index, "genesis")
      assert {:ok, encoded} = Record.encode(record)
      assert encoded.encoded_bytes == byte_size(encoded.bytes)
      assert encoded.digest =~ ~r/^sha256:[0-9a-f]{64}$/
      assert {:ok, decoded} = Record.decode(encoded.bytes)
      assert decoded == encoded
    end
  end

  test "key order does not change canonical bytes or the digest" do
    record = record("input_receipt", 0, "genesis")
    reordered = record |> Enum.reverse() |> Map.new()

    assert {:ok, first} = Record.encode(record)
    assert {:ok, second} = Record.encode(reordered)
    assert first.bytes == second.bytes
    assert first.digest == second.digest
  end

  test "unknown, mistyped, future, and oversized records fail before encoding" do
    record = record("input_receipt", 0, "genesis")

    assert {:error, {:unknown_record_payload_fields, ["extra"]}} =
             record |> put_in(["payload", "extra"], true) |> Record.encode()

    assert {:error, {:invalid_record_payload_type, "payload_digest"}} =
             record |> put_in(["payload", "payload_digest"], 1) |> Record.encode()

    assert {:error, :incompatible_future_store_format} =
             record |> Map.put("store_format_version", 2) |> Record.encode()

    oversized = String.duplicate("x", 262_144)
    command = record("command_receipt", 0, "genesis")

    assert {:error, {:oversized_record, size, 262_144}} =
             command |> put_in(["payload", "effective_arguments"], oversized) |> Record.encode()

    assert size > 262_144
  end

  test "runtime, renderer, raw-client, and credential structures fail with redacted results" do
    base = record("canonical_console_event", 0, "genesis")

    for forbidden <- [
          %{"pid" => self()},
          %{"callback" => fn -> :ok end},
          %{"draft" => "renderer state"},
          %{"provider_client" => %{}},
          %{"api_key" => "CANARY_DO_NOT_STORE"},
          %{"url" => "https://example.test/path?token=CANARY_DO_NOT_STORE"},
          %{"arguments" => ["--password=CANARY_DO_NOT_STORE"]}
        ] do
      candidate = put_in(base, ["payload", "event"], forbidden)
      assert {:error, {:sensitive_value_rejected, details}} = Record.encode(candidate)
      assert details["redacted"] == true
      refute inspect(details) =~ "CANARY_DO_NOT_STORE"
    end

    safe = put_in(base, ["payload", "event"], %{"text" => "Normal text can name ${SERVICE_TOKEN}."})
    assert {:ok, _encoded} = Record.encode(safe)
  end

  test "invalid envelopes and chain items return typed errors" do
    base = record("input_receipt", 0, "genesis")

    assert {:error, :invalid_record} = Record.encode(:not_a_record)
    assert {:error, :invalid_record_bytes} = Record.decode(:not_bytes)
    assert {:error, :invalid_record_chain} = Record.verify_chain(:not_a_chain)

    cases = [
      {Map.delete(base, "record_id"), {:missing_record_fields, ["record_id"]}},
      {Map.put(base, "extra", true), {:unknown_record_fields, ["extra"]}},
      {Map.put(base, "record_schema", "unknown"), :incompatible_record_schema},
      {Map.put(base, "record_schema_version", 2), :incompatible_record_schema},
      {Map.put(base, "record_id", ""), :invalid_record_id},
      {Map.put(base, "scope_id", ""), :invalid_record_scope},
      {Map.put(base, "generation", -1), :invalid_record_generation},
      {Map.put(base, "sequence", -1), :invalid_record_sequence},
      {Map.put(base, "prior_record_digest", "invalid"), :invalid_prior_record_digest},
      {Map.put(base, "payload", []), :invalid_record_payload},
      {update_in(base, ["payload"], &Map.delete(&1, "input_id")), {:missing_record_payload_fields, ["input_id"]}}
    ]

    for {candidate, reason} <- cases do
      assert {:error, ^reason} = Record.encode(candidate)
    end

    assert {:error, {:invalid_record, "index:0", :invalid_record_chain_item}} =
             Record.verify_chain([:not_a_record])

    first = base |> encode!()
    invalid_sequence = record("input_receipt", 2, first.digest) |> encode!()

    assert {:error, {:invalid_record, "record-2", {:record_sequence_mismatch, 0}}} =
             Record.verify_chain([first, invalid_sequence])

    assert {:error, {:invalid_record, "broken", {:invalid_json, _reason}}} =
             Record.verify_chain([%{bytes: "{", digest: "invalid", record_id: "broken"}])
  end

  test "optional null fields and genesis digests retain their declared types" do
    cases = [
      record("session_manifest", 0, "genesis") |> put_in(["payload", "terminal_status"], nil),
      record("canonical_console_event", 0, "genesis") |> put_in(["payload", "jidoka_link"], nil),
      record("interaction_permission", 0, "genesis") |> put_in(["payload", "expires_at_ms"], nil),
      record("effect_resolution", 0, "genesis") |> put_in(["payload", "result_digest"], nil),
      record("audit_chain", 0, "genesis") |> put_in(["payload", "prior_digest"], "genesis")
    ]

    for candidate <- cases do
      assert {:ok, encoded} = Record.encode(candidate)
      assert {:ok, ^encoded} = Record.decode(encoded.bytes)
    end

    assert {:error, :noncanonical_record} =
             Record.decode(~s({"store_format_version":1,"record_schema":"jido.console.record"}))
  end

  test "tamper, deletion, insertion, and reordering name the exact invalid record" do
    first = record("input_receipt", 0, "genesis") |> encode!()
    second = record("input_receipt", 1, first.digest) |> encode!()
    third = record("input_receipt", 2, second.digest) |> encode!()
    first_digest = first.digest

    assert :ok = Record.verify_chain([first, second, third])

    assert {:error, {:invalid_record, "record-2", {:prior_record_digest_mismatch, ^first_digest}}} =
             Record.verify_chain([first, third])

    assert {:error, {:invalid_record, "record-1", {:prior_record_digest_mismatch, "genesis"}}} =
             Record.verify_chain([second, first, third])

    inserted = record("input_receipt", 1, first.digest) |> Map.put("record_id", "inserted") |> encode!()
    inserted_digest = inserted.digest

    assert {:error, {:invalid_record, "record-1", {:prior_record_digest_mismatch, ^inserted_digest}}} =
             Record.verify_chain([first, inserted, second, third])

    tampered_bytes = String.replace(second.bytes, "record-1", "record-x")
    tampered = %{second | bytes: tampered_bytes}
    assert {:error, {:invalid_record, "record-x", :record_digest_mismatch}} = Record.verify_chain([first, tampered])
  end

  defp record(type, sequence, prior) do
    payload =
      case type do
        "credential_profile_reference" ->
          credential_profile()

        "effect_reservation" ->
          effect_reservation()

        "effect_resolution" ->
          effect_resolution()

        "verified_watermark" ->
          verified_watermark()

        _other ->
          {:ok, declaration} = Catalog.record_type(type)
          Map.new(declaration["required"], &{&1, field_value(&1)})
      end

    Record.new(type, payload,
      record_id: "record-#{sequence}",
      scope_id: "session-fixture",
      generation: 1,
      sequence: sequence,
      prior_record_digest: prior
    )
  end

  defp field_value(field) do
    {:ok, type} = Catalog.field_type(field)
    Map.fetch!(@field_values, type)
  end

  defp credential_profile do
    %{
      "profile_id" => "profile-fixture",
      "profile_version" => 1,
      "source_identity" => "host-fixture",
      "references" => [
        %{
          "reference_id" => "openai-fixture",
          "kind" => "environment",
          "source_identity" => "host-fixture",
          "lookup" => %{"name" => "OPENAI_API_KEY"}
        }
      ]
    }
  end

  defp effect_reservation do
    %{
      "session_id" => "session-fixture",
      "request_id" => "request-fixture",
      "effect_id" => "effect-fixture",
      "attempt_id" => "attempt-fixture",
      "result_id" => "result-fixture",
      "effect_kind" => "operation",
      "effective_arguments" => %{},
      "arguments_digest" => @digest,
      "safety_class" => "safe",
      "replay_rule" => "replay",
      "required_permission" => "none",
      "approval_id" => nil,
      "turn_manifest_digest" => @digest,
      "generation" => 1,
      "jidoka_intent_id" => "effect-fixture",
      "jidoka_idempotency_key" => "key-fixture",
      "credential_reference_id" => nil,
      "workspace_digest" => @digest
    }
  end

  defp effect_resolution do
    %{
      "session_id" => "session-fixture",
      "effect_id" => "effect-fixture",
      "attempt_id" => "attempt-fixture",
      "result_id" => "result-fixture",
      "status" => "failed",
      "jidoka_intent_id" => "effect-fixture",
      "jidoka_revision" => 1
    }
  end

  defp verified_watermark do
    %{
      "watermark_id" => "watermark-fixture",
      "console_identity" => %{
        "session_id" => "session-fixture",
        "generation" => 1,
        "sequence" => 1,
        "event_id" => "event-fixture",
        "operation_id" => "console-operation-fixture",
        "chain_digest" => @digest
      },
      "console_digest" => @digest,
      "jidoka_identity" => %{
        "session_id" => "session-fixture",
        "revision" => 2,
        "request_id" => "request-fixture",
        "lease_id" => "lease-fixture",
        "snapshot_id" => "snapshot-fixture",
        "operation_id" => "jidoka-operation-fixture",
        "value_digest" => @digest
      },
      "jidoka_digest" => @digest,
      "state" => "reserved"
    }
  end

  defp encode!(record) do
    {:ok, encoded} = Record.encode(record)
    Map.put(encoded, :record_id, record["record_id"])
  end
end
