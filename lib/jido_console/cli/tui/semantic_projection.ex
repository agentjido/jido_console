defmodule Jido.Console.Tui.SemanticProjection do
  @moduledoc "Canonical Console event projection for renderer-local TUI state."

  alias Jido.Console.Tui.SafeText

  @event_names %{
    "model_delta" => :model_delta,
    "tool_started" => :tool_started,
    "tool_completed" => :tool_completed,
    "tool_failed" => :tool_failed,
    "permission_requested" => :permission_requested,
    "permission_decided" => :permission_decided,
    "run_completed" => :run_completed,
    "run_failed" => :run_failed,
    "session_failed" => :session_failed,
    "control_requested" => :control_requested,
    "control_completed" => :control_completed,
    "command_effected" => :command_effected,
    "run_started" => :run_started,
    "input_admitted" => :input_admitted,
    "queue_changed" => :queue_changed
  }

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              request_id: Zoi.string() |> Zoi.nullish(),
              seq: Zoi.integer() |> Zoi.gte(0),
              event: Zoi.atom(),
              kind: Zoi.atom(),
              data: Zoi.map()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          id: String.t(),
          request_id: String.t() | nil,
          seq: non_neg_integer(),
          event: atom(),
          kind: :assistant_delta | :tool | :review | :outcome | :event,
          data: map()
        }

  @doc "Projects one validated canonical event into bounded TUI data."
  @spec project(map(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def project(event, request_id \\ nil) do
    payload = event["payload"] || %{}
    type = event["type"]

    with true <- event["family"] == "event",
         sequence when is_integer(sequence) and sequence >= 0 <- payload["sequence"],
         {:ok, name} <- event_name(type) do
      {:ok,
       %__MODULE__{
         id: event["id"],
         request_id: event_request_id(payload, request_id),
         seq: sequence,
         event: name,
         kind: kind(type),
         data: data(type, payload)
       }}
    else
      false -> {:error, :invalid_semantic_event}
      nil -> {:error, :invalid_semantic_sequence}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kind("model_delta"), do: :assistant_delta
  defp kind(type) when type in ~w(tool_started tool_completed tool_failed), do: :tool
  defp kind(type) when type in ~w(permission_requested permission_decided), do: :review
  defp kind(type) when type in ~w(run_completed run_failed session_failed), do: :outcome
  defp kind(_type), do: :event

  defp data("model_delta", payload), do: %{text: SafeText.clean(payload["text"] || "")}

  defp data(type, payload) when type in ~w(tool_started tool_completed tool_failed) do
    %{
      id: payload["step_id"],
      operation: optional(payload["operation"]),
      status: tool_status(type, payload),
      loop_index: nil,
      summary: SafeText.summary(payload["content"] || payload["reason"] || payload["operation"] || type),
      error: if(type == "tool_failed", do: optional(payload["reason"]))
    }
  end

  defp data("permission_requested", payload) do
    review = payload["review"] || %{}

    %{
      id: payload["approval_id"] || review["interrupt_id"] || review["id"],
      operation: optional(review["operation"]),
      status: permission_status("permission_requested", nil),
      reason: optional(review["reason"]),
      decision: nil,
      expires_at_ms: review["expires_at_ms"],
      summary: SafeText.summary(review["arguments"] || payload["scope"] || "permission_requested")
    }
  end

  defp data("permission_decided", payload) do
    %{
      id: payload["approval_id"],
      status: permission_status("permission_decided", payload["decision"]),
      decision: payload["decision"],
      summary: SafeText.summary(payload["decision"] || "permission_decided")
    }
  end

  defp data("control_completed", payload), do: %{result: payload["result"]}

  defp data(type, payload) when type in ~w(run_completed run_failed session_failed) do
    %{
      status: outcome_status(type, payload),
      error: optional(payload["reason"]),
      summary: SafeText.summary(payload["content"] || payload["reason"] || type)
    }
  end

  defp data(_type, _payload), do: %{}

  defp event_request_id(payload, fallback) do
    identity =
      Enum.find(payload["identities"] || [], fn identity ->
        identity["kind"] == "jidoka_request"
      end)

    (identity && identity["id"]) || payload["turn_id"] || fallback
  end

  defp event_name(type) when is_binary(type) do
    {:ok, Map.get(@event_names, type, :event)}
  end

  defp event_name(_type), do: {:error, :invalid_semantic_event_type}

  defp tool_status("tool_started", _payload), do: :running

  defp tool_status("tool_completed", %{"content" => %{"event" => "effect_replayed"}}),
    do: :retried

  defp tool_status("tool_completed", _payload), do: :completed
  defp tool_status("tool_failed", _payload), do: :failed

  defp permission_status("permission_requested", _decision), do: :pending
  defp permission_status("permission_decided", "approved"), do: :approved
  defp permission_status("permission_decided", "denied"), do: :denied
  defp permission_status("permission_decided", _decision), do: :completed

  defp outcome_status("run_completed", _payload), do: :completed

  defp outcome_status("run_failed", %{"reason" => "cancelled"}), do: :cancelled
  defp outcome_status("run_failed", %{"reason" => "hibernated"}), do: :hibernated
  defp outcome_status(_type, _payload), do: :failed

  defp optional(nil), do: nil
  defp optional(value), do: SafeText.summary(value)
end
