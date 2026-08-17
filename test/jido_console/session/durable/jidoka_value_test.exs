defmodule Jido.Console.Session.Durable.JidokaValueTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, JidokaValue}
  alias Jidoka.Session.Data

  setup do
    assert {:ok, session} = Data.start(Jido.Console.DefaultAgent.spec(), session_id: "jidoka-codec-fixture")
    %{session: session}
  end

  test "opaque bytes round trip through the public Jidoka schema", %{session: session} do
    assert {:ok, encoded} = JidokaValue.encode(session)
    assert encoded.envelope["jidoka_schema_version"] == Data.schema_version()
    assert encoded.envelope["jidoka_revision"] == session.revision
    assert encoded.envelope["encoded_value_bytes"] <= 134_217_728

    assert {:ok, decoded} = JidokaValue.decode(encoded.bytes)
    assert %Data{} = decoded.value
    assert decoded.value.session_id == session.session_id
    assert decoded.value.schema_version == session.schema_version
    assert decoded.value.revision == session.revision
    assert decoded.bytes == encoded.bytes
  end

  test "digest, size, envelope, and public-schema tamper fail", %{session: session} do
    assert {:ok, encoded} = JidokaValue.encode(session)

    assert {:error, :jidoka_value_digest_mismatch} =
             encoded.envelope
             |> Map.put("value_digest", "sha256:" <> String.duplicate("0", 64))
             |> encode_envelope()
             |> JidokaValue.decode()

    assert {:error, :jidoka_value_size_mismatch} =
             encoded.envelope
             |> Map.update!("encoded_value_bytes", &(&1 + 1))
             |> encode_envelope()
             |> JidokaValue.decode()

    assert {:error, :incompatible_jidoka_envelope} =
             encoded.envelope |> Map.put("version", 2) |> encode_envelope() |> JidokaValue.decode()

    invalid_value = Map.put(encoded.envelope["encoded_value"], "session_id", "")
    invalid_envelope = reidentify(encoded.envelope, invalid_value)

    assert {:error, {:invalid_jidoka_value, _reason}} =
             invalid_envelope |> encode_envelope() |> JidokaValue.decode()
  end

  test "credential-bearing, runtime, and oversized Jidoka values fail before encoding", %{session: session} do
    credential = %{session | metadata: %{"api_key" => "CANARY_DO_NOT_STORE"}}
    runtime = %{session | metadata: %{"worker" => self()}}

    for value <- [credential, runtime] do
      assert {:error, {:sensitive_value_rejected, details}} = JidokaValue.encode(value)
      assert details["redacted"] == true
      refute inspect(details) =~ "CANARY_DO_NOT_STORE"
    end

    assert {:error, {:oversized_jidoka_value, size, 64}} = JidokaValue.encode(session, max_bytes: 64)
    assert size > 64
  end

  test "invalid envelope shapes fail before public schema validation", %{session: session} do
    assert {:error, :invalid_jidoka_value} = JidokaValue.encode(%{})
    assert {:error, :invalid_jidoka_value_bytes} = JidokaValue.decode(:not_bytes)
    assert {:ok, encoded} = JidokaValue.encode(session)

    assert {:error, {:missing_jidoka_envelope_fields, ["schema"]}} =
             encoded.envelope |> Map.delete("schema") |> encode_envelope() |> JidokaValue.decode()

    assert {:error, {:unknown_jidoka_envelope_fields, ["extra"]}} =
             encoded.envelope |> Map.put("extra", true) |> encode_envelope() |> JidokaValue.decode()

    assert {:error, :invalid_jidoka_envelope} = "[]" |> JidokaValue.decode()

    reserved = %{session | metadata: %{"$jido.reserved" => true}}
    assert {:error, {:reserved_jidoka_key, "$jido.reserved"}} = JidokaValue.encode(reserved)
  end

  test "portable tuple and atom tags are strict and canonical", %{session: session} do
    assert {:ok, encoded} = JidokaValue.encode(session)

    noncanonical =
      encoded.envelope
      |> Map.to_list()
      |> Enum.reverse()
      |> Jason.OrderedObject.new()
      |> Jason.encode!()

    assert {:error, :noncanonical_jidoka_envelope} = JidokaValue.decode(noncanonical)

    tuple_value =
      put_in(encoded.envelope["encoded_value"], ["metadata", "tuple"], %{
        "$jido.tuple" => [%{"$jido.atom" => "ok"}, 1]
      })

    assert {:ok, tuple_decoded} =
             encoded.envelope |> reidentify(tuple_value) |> encode_envelope() |> JidokaValue.decode()

    assert tuple_decoded.value.metadata["tuple"] == {:ok, 1}

    unknown_atom = "jido_console_atom_that_must_not_be_created_during_decode"

    unknown_value =
      put_in(encoded.envelope["encoded_value"], ["metadata", "items"], [
        %{"$jido.atom" => unknown_atom}
      ])

    assert {:error, {:unknown_jidoka_atom, ^unknown_atom}} =
             encoded.envelope |> reidentify(unknown_value) |> encode_envelope() |> JidokaValue.decode()
  end

  defp reidentify(envelope, value) do
    {:ok, value_bytes} = CanonicalJSON.encode(value)

    envelope
    |> Map.put("encoded_value", value)
    |> Map.put("encoded_value_bytes", byte_size(value_bytes))
    |> Map.put("value_digest", Digest.portable(value_bytes))
  end

  defp encode_envelope(envelope) do
    {:ok, bytes} = CanonicalJSON.encode(envelope)
    bytes
  end
end
