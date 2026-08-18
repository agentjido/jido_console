defmodule Jido.Console.Session.GenerationTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Durable.Record
  alias Jido.Console.Session.Generation
  alias Jido.Console.Storage

  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jido-generation-#{System.unique_integer([:positive])}")

    names = [
      name: unique(:supervisor),
      lock: unique(:lock),
      maintenance: unique(:maintenance),
      quota: unique(:quota),
      admission: unique(:admission),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, _supervisor} = Jido.Console.Storage.Supervisor.start_link(names)
    on_exit(fn -> File.rm_rf(root) end)

    %{storage: Keyword.take(names, [:writer, :quota, :admission])}
  end

  test "claims larger owners and keeps old operations fenced", %{storage: storage} do
    assert {:ok, first} =
             Generation.claim(
               "session-generation",
               storage ++
                 [
                   expected_generation: 0,
                   owner_instance_id: "owner-first",
                   operation_id: "claim-first",
                   jidoka_lease_id: "jidoka-first"
                 ]
             )

    assert first.generation == 1
    assert first.owner_instance_id == "owner-first"
    assert first.jidoka_lease_id == "jidoka-first"
    refute first.owner_instance_id == first.jidoka_lease_id

    assert {:ok, linked} = Generation.bind_jidoka_lease(first, "jidoka-watermark")
    assert linked.generation == first.generation
    assert linked.owner_instance_id == first.owner_instance_id
    assert linked.jidoka_lease_id == "jidoka-watermark"

    append_operation = "append-first"
    append_fence = Generation.for_operation(first, append_operation)

    assert {:ok, %{sequence: 0}} =
             Storage.append(
               record(0, "genesis"),
               storage ++ [operation_id: append_operation, fence: append_fence]
             )

    assert {:ok, second} =
             Generation.claim(
               "session-generation",
               storage ++
                 [
                   expected_generation: 1,
                   owner_instance_id: "owner-second",
                   operation_id: "claim-second"
                 ]
             )

    assert second.generation == 2
    assert Generation.stale?(second, first)
    refute Generation.same?(second, first)

    stale_operation = "append-stale"

    assert {:error, {:stale_generation, "session-generation", 1, 2}} =
             Storage.append(
               record(0, "genesis") |> Map.put("generation", 2),
               storage ++
                 [
                   operation_id: stale_operation,
                   fence: Generation.for_operation(first, stale_operation)
                 ]
             )

    assert {:error, {:stale_generation, "session-generation", 1, 2}} =
             Generation.release(first, storage ++ [operation_id: "release-stale"])

    assert {:ok, released} =
             Generation.release(second, storage ++ [operation_id: "release-second"])

    assert released.state == :released

    assert {:ok, audit} = Generation.audit("session-generation", storage)

    assert Enum.map(audit, &{&1.generation, &1.transition}) == [
             {1, :claimed},
             {2, :claimed},
             {2, :released}
           ]
  end

  test "generates bounded identities and exposes one protocol-safe fence", %{storage: storage} do
    assert {:ok, claimed} = Generation.claim("generated-session", storage)
    assert claimed.generation == 1
    assert claimed.state == :active
    assert String.starts_with?(claimed.owner_instance_id, "own-")
    assert String.starts_with?(claimed.operation_id, "generation-claim-")

    assert {:ok, inspected} = Generation.inspect("generated-session", storage)
    assert inspected.generation == claimed.generation
    assert inspected.owner_instance_id == claimed.owner_instance_id

    protocol = Generation.to_protocol(claimed)
    assert protocol["session_id"] == "generated-session"
    assert protocol["generation"] == 1
    assert protocol["owner_instance_id"] == claimed.owner_instance_id
    assert protocol["operation_id"] == claimed.operation_id
    assert protocol["jidoka_lease_id"] == nil
    assert protocol["state"] == "active"

    assert {:ok, released} = Generation.release(claimed, storage)
    assert released.state == :released
    assert String.starts_with?(released.operation_id, "generation-release-")

    assert {:ok, audit} = Generation.audit("generated-session", storage)
    assert Enum.map(audit, & &1.transition) == [:claimed, :released]
  end

  test "validates comparisons, link identities, and invalid options", %{storage: storage} do
    current = fence("same-session", 2, "owner-current")
    same = fence("same-session", 2, "owner-current")
    older = fence("same-session", 1, "owner-old")
    replaced = fence("same-session", 2, "owner-old")
    other = fence("other-session", 1, "owner-old")

    assert Generation.same?(current, same)
    refute Generation.same?(current, older)
    assert Generation.stale?(current, older)
    assert Generation.stale?(current, replaced)
    refute Generation.stale?(current, current)
    refute Generation.stale?(current, other)
    assert :ok = Generation.validate(current)
    assert {:error, :invalid_generation_fence} = Generation.validate(:invalid)

    assert {:ok, linked} = Generation.bind_jidoka_lease(current, "lease-current")
    assert linked.jidoka_lease_id == "lease-current"

    assert {:error, {:invalid_generation_token, :jidoka_lease_id}} =
             Generation.bind_jidoka_lease(current, "")

    assert {:error, {:invalid_generation_token, :session_id}} = Generation.claim("", storage)

    assert {:error, :invalid_expected_generation} =
             Generation.claim("invalid-expected", storage ++ [expected_generation: -1])

    assert {:error, {:invalid_generation_token, :owner_instance_id}} =
             Generation.claim("invalid-owner", storage ++ [owner_instance_id: ""])

    assert {:error, {:invalid_generation_token, :operation_id}} =
             Generation.claim("invalid-operation", storage ++ [operation_id: ""])

    assert {:error, :invalid_generation} = Generation.release(%{}, storage)
    assert {:error, :invalid_generation} = Generation.validate(%{current | generation: 0})
    assert {:error, :invalid_generation} = Generation.validate(%{current | generation: nil})
  end

  defp record(sequence, prior) do
    Record.new(
      "input_receipt",
      %{
        "operation_id" => "operation-#{sequence}",
        "idempotency_key" => "idempotency-#{sequence}",
        "payload_digest" => @digest,
        "input_id" => "input-#{sequence}",
        "admission_state" => "accepted"
      },
      scope_id: "session-generation",
      generation: 1,
      sequence: sequence,
      prior_record_digest: prior,
      record_id: "generation-record-#{sequence}"
    )
  end

  defp fence(session_id, generation, owner_instance_id) do
    %{
      session_id: session_id,
      generation: generation,
      owner_instance_id: owner_instance_id,
      operation_id: "operation",
      state: :active
    }
  end

  defp unique(label),
    do: String.to_atom("jido-generation-#{label}-#{System.unique_integer([:positive])}")
end
