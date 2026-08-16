defmodule Jido.Console.Session.Client.TUI do
  @moduledoc """
  Terminal UI projection of a supervised session.

  Renderer-only state stays local to the TUI. Session work continues after
  detach.
  """

  alias Jido.Console.Session.Client

  @doc "Attaches the TUI to a supervised session."
  @spec attach(String.t(), keyword()) :: {:ok, Client.t()} | {:error, term()}
  def attach(session_id, opts \\ []), do: Client.attach(session_id, opts)

  @doc "Detaches the TUI while the session remains alive."
  @spec detach(Client.t()) :: :ok | {:error, term()}
  def detach(handle), do: Client.detach(handle)

  @doc "Reattaches the TUI to the same session."
  @spec reattach(Client.t(), keyword()) :: {:ok, Client.t()} | {:error, term()}
  def reattach(handle, opts \\ []) do
    _ = Client.detach(handle)
    Client.attach(handle.session.id, opts)
  end

  @doc "Returns ordered semantic event types visible to the TUI client."
  @spec observe(Client.t()) :: [String.t()]
  def observe(handle) do
    handle
    |> Client.snapshot()
    |> get_in(["payload", "state", "transcript"])
    |> List.wrap()
    |> Enum.map(& &1["type"])
  end
end
