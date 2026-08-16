defmodule Jido.Console.Session.Client.Automation do
  @moduledoc """
  Automation projection of a supervised session.

  Each evaluation matrix cell attaches one fresh session. Published JSONL
  schemas and exit statuses stay outside this module.
  """

  alias Jido.Console.Session.Client

  @doc "Attaches automation to one fresh session for a matrix cell."
  @spec attach_cell(String.t(), keyword()) :: {:ok, Client.t()} | {:error, term()}
  def attach_cell(session_id, opts \\ []), do: Client.attach(session_id, opts)

  @doc "Returns ordered semantic event types visible to automation."
  @spec observe(Client.t()) :: [String.t()]
  def observe(handle) do
    handle
    |> Client.snapshot()
    |> get_in(["payload", "state", "transcript"])
    |> List.wrap()
    |> Enum.map(& &1["type"])
  end
end
