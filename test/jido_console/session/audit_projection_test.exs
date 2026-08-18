defmodule Jido.Console.Session.AuditProjectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.AuditProjection
  alias Jido.Console.Session.Durable.Record

  @canary "AUDIT_CREDENTIAL_CANARY_DO_NOT_EXPORT"

  test "exports a portable redacted chain and verifies it offline" do
    records = chain()

    assert {:ok, audit} =
             AuditProjection.export(records,
               watermark: %{"id" => "watermark-main", "state" => "verified"},
               fork: %{"parent_session_id" => "parent-main"},
               forbidden_values: [@canary]
             )

    assert :ok = AuditProjection.verify(audit)
    assert audit["entry_count"] == 3
    assert audit["head_digest"] == audit["entries"] |> List.last() |> Map.fetch!("audit_digest")
    assert Jason.encode!(audit)
    refute inspect(audit) =~ @canary

    for entry <- audit["entries"] do
      assert entry["origin"] == "session"
      assert entry["trust"] == "owner"
      assert entry["generation"] == 1
      assert entry["watermark"]["state"] == "verified"
      assert entry["fork"]["parent_session_id"] == "parent-main"
      assert Map.has_key?(entry["payload"], "event_digest")
      refute Map.has_key?(entry["payload"], "event")
    end
  end

  test "detects mutation, deletion, insertion, and reorder" do
    assert {:ok, audit} = AuditProjection.export(chain())
    [first, second, third] = audit["entries"]

    mutation = put_in(audit, ["entries", Access.at(1), "sequence"], 99)
    assert {:error, {:audit_chain_mismatch, "event-2"}} = AuditProjection.verify(mutation)

    deletion = %{audit | "entries" => [first, third], "entry_count" => 2}
    assert {:error, {:audit_chain_mismatch, "event-3"}} = AuditProjection.verify(deletion)

    insertion = %{audit | "entries" => [first, first, second, third], "entry_count" => 4}
    assert {:error, {:audit_chain_mismatch, "event-1"}} = AuditProjection.verify(insertion)

    reorder = %{audit | "entries" => [second, first, third]}
    assert {:error, {:audit_chain_mismatch, "event-2"}} = AuditProjection.verify(reorder)

    assert {:error, :audit_projection_digest_mismatch} =
             AuditProjection.verify(Map.put(audit, "head_digest", "sha256:" <> String.duplicate("0", 64)))

    assert {:error, :audit_projection_digest_mismatch} =
             AuditProjection.verify(Map.put(audit, "export_digest", "sha256:" <> String.duplicate("0", 64)))

    assert {:error, :invalid_audit_projection} = AuditProjection.verify(%{})
    assert {:error, :invalid_audit_source} = AuditProjection.export(:invalid)
  end

  test "rejects credential canaries and invalid authoritative chains with redacted errors" do
    assert {:error, {:forbidden_audit_value, %{"redacted" => true}}} =
             AuditProjection.scan(%{"text" => @canary}, [@canary])
             |> redact_forbidden_error()

    assert {:error, {:forbidden_audit_value, %{"redacted" => true}}} =
             AuditProjection.scan(%{@canary => "redacted"}, [@canary])
             |> redact_forbidden_error()

    [first, _second, third] = chain()

    assert {:error, {:invalid_audit_source_chain, _reason}} =
             AuditProjection.export([first, third])

    assert {:error, {:invalid_audit_source_chain, _reason}} =
             AuditProjection.export(Enum.reverse(chain()))
  end

  defp chain do
    Enum.reduce(1..3, {[], "genesis"}, fn sequence, {records, prior} ->
      record =
        Record.new("canonical_console_event", payload(sequence),
          record_id: "event-#{sequence}",
          scope_id: "session-main",
          generation: 1,
          sequence: sequence,
          prior_record_digest: prior
        )

      {:ok, encoded} = Record.encode(record)
      {records ++ [encoded], encoded.digest}
    end)
    |> elem(0)
  end

  defp payload(sequence) do
    %{
      "event_id" => "event-#{sequence}",
      "sequence" => sequence,
      "event_class" => "run_progress",
      "origin" => "session",
      "trust" => "owner",
      "sensitivity" => "public",
      "event" => %{"id" => "event-#{sequence}", "text" => "safe event #{sequence}"}
    }
  end

  defp redact_forbidden_error({:error, {:forbidden_audit_value, details}}),
    do: {:error, {:forbidden_audit_value, Map.take(details, ["redacted"])}}
end
