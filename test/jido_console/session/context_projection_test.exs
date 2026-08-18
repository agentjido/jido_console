defmodule Jido.Console.Session.ContextProjectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.ContextProjection

  defmodule Storage do
    def history_suffix(session_id, opts) do
      send(opts[:test_pid], {:history_suffix, session_id, opts})
      {:ok, opts[:source_records]}
    end
  end

  test "rebuilds the same bounded projection without changing canonical sources" do
    records = Enum.map(1..5, &record/1)
    original = :erlang.term_to_binary(records)

    assert {:ok, first} = ContextProjection.project("session-main", records, context_events: 3)
    assert {:ok, ^first} = ContextProjection.project("session-main", records, context_events: 3)
    assert :erlang.term_to_binary(records) == original
    assert first["source_start_sequence"] == 3
    assert first["source_end_sequence"] == 5
    assert first["event_count"] == 3
    assert Enum.map(first["events"], & &1["id"]) == ~w(event-3 event-4 event-5)
    assert first["projection_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert first["source_range_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  test "compacts by encoded bytes and rejects gaps and invalid bounds" do
    records =
      1..3
      |> Enum.map(&record/1)
      |> Enum.map(&put_in(&1, [:event, "payload", "text"], String.duplicate("x", 600)))

    assert {:ok, projection} =
             ContextProjection.project("session-main", records, context_bytes: 1_400)

    assert projection["event_count"] == 1
    assert projection["source_start_sequence"] == 3

    assert {:error, :context_source_gap} =
             ContextProjection.project("session-main", [record(1), record(3)])

    assert {:error, :invalid_context_projection_bounds} =
             ContextProjection.project("session-main", records, context_events: 257)

    assert ContextProjection.limits().context_bytes == 1_048_576
  end

  test "builds from bounded storage and returns typed malformed-source results" do
    records = Enum.map(1..2, &record/1)

    assert {:ok, projection} =
             ContextProjection.build("session-main",
               storage: Storage,
               source_records: records,
               test_pid: self()
             )

    assert projection["event_count"] == 2

    assert_receive {:history_suffix, "session-main", opts}
    assert opts[:limit] == 1_000
    assert opts[:max_bytes] == 8_388_608

    assert {:ok, empty} = ContextProjection.project("session-main", [])
    assert empty["source_chain_digest"] == "genesis"

    assert {:error, :invalid_context_source_record} =
             ContextProjection.project("session-main", [%{event: %{}, sequence: 1, record_digest: "invalid"}])

    assert {:error, :context_projection_limit} =
             ContextProjection.project("session-main", records, context_bytes: 1)

    assert {:error, :invalid_context_projection} = ContextProjection.project(:invalid, :invalid)
  end

  defp record(sequence) do
    %{
      event: %{
        "id" => "event-#{sequence}",
        "type" => "run_progress",
        "payload" => %{"sequence" => sequence, "text" => "event #{sequence}"}
      },
      sequence: sequence,
      record_digest: "sha256:" <> String.pad_leading(Integer.to_string(sequence, 16), 64, "0")
    }
  end
end
