defmodule Jido.Console.Session.Client.Boundary do
  @moduledoc """
  Structural guard for production session client adapters.

  The fixed legacy exception belongs only to the M2-E27 TUI migration. The
  exception cannot be extended by callers and is removed in M2-E32.
  """

  @legacy_allowlist ["lib/jido_console/cli/tui.ex"]
  @forbidden [
    "Jido.Console.Session.Server",
    "Jido.Console.Session.Delivery",
    "Jido.Console.Session.Recovery",
    "Jidoka.Session",
    "Jidoka.Event"
  ]

  @doc "Returns the one fixed temporary legacy path."
  @spec legacy_allowlist() :: [String.t()]
  def legacy_allowlist, do: @legacy_allowlist

  @doc "Checks adapter source paths for direct internal session access."
  @spec check([String.t()], String.t()) :: :ok | {:error, term()}
  def check(paths, root \\ File.cwd!()) do
    paths
    |> Enum.reject(&(&1 in @legacy_allowlist))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      source = File.read!(Path.join(root, path))

      case Enum.find(@forbidden, &String.contains?(source, &1)) do
        nil -> {:cont, :ok}
        boundary -> {:halt, {:error, {:client_boundary_bypass, path, boundary}}}
      end
    end)
  end
end
