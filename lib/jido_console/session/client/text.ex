defmodule Jido.Console.Session.Client.Text do
  @moduledoc "Human-readable text projection of Session.Client outcomes."

  alias Jido.Console.Session.Client

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
    Enum.map_join(events, "\n", &render/1)
  end

  @doc "Returns ordered semantic event types after text projection."
  @spec observe(Client.t()) :: [String.t()]
  def observe(handle) do
    events =
      handle
      |> Client.snapshot()
      |> get_in(["payload", "state", "transcript"])
      |> List.wrap()

    Enum.map(events, fn event ->
      _line = render(event)
      event["type"]
    end)
  end

  defp reason(event) do
    get_in(event, ["payload", "reason"]) || event["reason"] || "failed"
  end
end
