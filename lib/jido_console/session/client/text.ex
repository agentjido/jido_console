defmodule Jido.Console.Session.Client.Text do
  @moduledoc "Human-readable text projection of Session.Client outcomes."

  @doc "Renders one ordered semantic outcome as plain text."
  @spec render(map()) :: String.t()
  def render(%{"type" => type} = event) do
    case type do
      "delivery_gap" -> "gap after #{event["last_acknowledged"] || 0}"
      "run_failed" -> "error: #{reason(event)}"
      other -> other
    end
  end

  def render(_event), do: "unknown"

  @doc "Renders an ordered transcript."
  @spec transcript([map()]) :: String.t()
  def transcript(events) when is_list(events) do
    events |> Enum.map(&render/1) |> Enum.join("\n")
  end

  defp reason(event) do
    get_in(event, ["payload", "reason"]) || event["reason"] || "failed"
  end
end
