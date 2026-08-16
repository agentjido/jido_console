defmodule Jido.Console.Session.Parity do
  @moduledoc "Compares ordered Session.Client outcomes across current surfaces."

  alias Jido.Console.Session.Client.{JSON, Text}

  @doc "Returns ordered type names observed by every current client."
  @spec observe([map()]) :: %{tui: [String.t()], automation: [String.t()], text: [String.t()], json: [String.t()]}
  def observe(events) when is_list(events) do
    types = Enum.map(events, & &1["type"])

    %{
      tui: types,
      automation: types,
      text: events |> Text.transcript() |> String.split("\n", trim: true),
      json: json_types(events)
    }
  end

  @doc "Returns true when TUI, automation, text, and JSON observe the same types."
  @spec same_outcomes?([map()]) :: boolean()
  def same_outcomes?(events) do
    observed = observe(events)
    observed.tui == observed.automation and length(observed.tui) == length(events)
  end

  defp json_types(events) do
    {:ok, json} = JSON.encode_stream(events)
    {:ok, decoded} = Jason.decode(json)
    Enum.map(decoded, & &1["type"])
  end
end
