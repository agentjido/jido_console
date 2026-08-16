defmodule Jido.Console.Session.Parity do
  @moduledoc "Compares live Session.Client observations across current surfaces."

  alias Jido.Console.Session.Client.{Automation, JSON, Text, TUI}

  @type handles :: %{
          required(:tui) => Jido.Console.Session.Client.t(),
          required(:automation) => Jido.Console.Session.Client.t(),
          required(:text) => Jido.Console.Session.Client.t(),
          required(:json) => Jido.Console.Session.Client.t()
        }

  @doc "Returns ordered event types observed from four live attachments."
  @spec observe(handles()) :: %{
          tui: [String.t()],
          automation: [String.t()],
          text: [String.t()],
          json: [String.t()]
        }
  def observe(%{tui: tui, automation: automation, text: text, json: json}) do
    %{
      tui: TUI.observe(tui),
      automation: Automation.observe(automation),
      text: Text.observe(text),
      json: JSON.observe(json)
    }
  end

  @doc "Returns true when all four live clients observe the same ordered events."
  @spec same_outcomes?(handles()) :: boolean()
  def same_outcomes?(handles) do
    observed = observe(handles)

    observed.tui == observed.automation and
      observed.tui == observed.text and
      observed.tui == observed.json
  end
end
