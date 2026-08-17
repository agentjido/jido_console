defmodule Jido.Console.Tui.SemanticProjectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.SemanticProjection

  test "keeps the canonical replay marker for tool rendering" do
    event = %{
      "family" => "event",
      "type" => "tool_completed",
      "id" => "event-replayed",
      "payload" => %{
        "sequence" => 3,
        "step_id" => "edit-implementation",
        "content" => %{"event" => "effect_replayed"}
      }
    }

    assert {:ok, projection} = SemanticProjection.project(event, "request-1")
    assert projection.data.status == :retried
  end

  test "a permission decision does not erase request display fields" do
    event = %{
      "family" => "event",
      "type" => "permission_decided",
      "id" => "event-approved",
      "payload" => %{
        "sequence" => 4,
        "approval_id" => "review-1",
        "decision" => "approved"
      }
    }

    assert {:ok, projection} = SemanticProjection.project(event, "request-1")
    assert projection.data.status == :approved
    refute Map.has_key?(projection.data, :operation)
    refute Map.has_key?(projection.data, :reason)
  end
end
