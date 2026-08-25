defmodule Jido.Console.Session.Client.JSON.ProtocolTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client.JSON.Protocol
  alias Jido.Console.Session.{Command, View}

  test "validates every version 1 input operation" do
    records = [
      base("attach"),
      base("reattach"),
      base("detach"),
      Map.merge(base("submit"), %{"text" => "hello", "request_id" => "request-1", "context" => %{}}),
      Map.put(base("cancel"), "request_id", "request-1"),
      Map.merge(base("approve"), %{"request_id" => "request-1", "review_id" => "review-1"}),
      Map.merge(base("deny"), %{"request_id" => "request-1", "review_id" => "review-1"}),
      Map.put(base("remove"), "queue_item_id", "queue-1"),
      Map.put(base("select_model"), "identity", "openai:gpt-4.1-mini"),
      base("status"),
      Map.merge(base("history"), %{"limit" => 10, "before_sequence" => 20}),
      base("stop")
    ]

    for record <- records do
      assert {:ok, decoded} = record |> Jason.encode!() |> Protocol.decode()

      unless record["type"] in ["attach", "reattach", "detach"] do
        assert {:ok, %Command{type: type}} = Protocol.command(decoded)
        assert Atom.to_string(type) == record["type"]
      end
    end
  end

  test "uses the input identity for a stable submit command" do
    input = Map.merge(base("submit"), %{"text" => "hello", "request_id" => "request-1"})
    assert {:ok, decoded} = input |> Jason.encode!() |> Protocol.decode()
    assert {:ok, command} = Protocol.command(decoded)
    assert command.id == input["id"]
    assert command.queue_item_id == input["id"]
    assert command.request_id == "request-1"
  end

  test "rejects malformed, unknown, extra, old, and oversized input" do
    assert {:error, {:invalid_json, _reason}, nil} = Protocol.decode("not json")

    assert {:error, {:unknown_json_command, "wat"}, identity} =
             base("wat") |> Jason.encode!() |> Protocol.decode()

    assert identity == %{"id" => "input-1", "thread_id" => "thread-1"}

    assert {:error, {:invalid_json_command, _errors}, _identity} =
             base("attach") |> Map.put("extra", true) |> Jason.encode!() |> Protocol.decode()

    assert {:error, {:invalid_json_command, _errors}, _identity} =
             base("attach") |> Map.put("version", 2) |> Jason.encode!() |> Protocol.decode()

    assert {:error, {:input_too_large, _size, 4}, nil} = Protocol.decode("12345", max_bytes: 4)
  end

  test "encodes complete views and rejects runtime values" do
    view =
      View.new!(
        thread_id: "thread-1",
        status: :running,
        revision: 4,
        transcript: [%{role: :user, content: "hello"}]
      )

    record = Protocol.view("thread-1", "attachment-1", view)
    assert {:ok, encoded} = Protocol.encode(record)
    assert {:ok, decoded} = encoded |> IO.iodata_to_binary() |> Jason.decode()
    assert decoded["view"]["status"] == "running"
    assert decoded["view"]["transcript"] == [%{"role" => "user", "content" => "hello"}]

    assert {:error, {:forbidden_runtime_value, :pid}} = Protocol.portable(self())
    assert {:error, {:forbidden_runtime_value, :reference}} = Protocol.portable(make_ref())
  end

  test "reports output size without truncation" do
    record = Protocol.success(base("status"), %{"text" => String.duplicate("x", 100)})
    assert {:error, {:output_too_large, size, 32}} = Protocol.encode(record, max_bytes: 32)
    assert size > 32
  end

  defp base(type) do
    %{
      "version" => 1,
      "id" => "input-1",
      "type" => type,
      "thread_id" => "thread-1"
    }
  end
end
