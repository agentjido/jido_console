defmodule Mix.Tasks.Jido.Protocol.Generate do
  @shortdoc "Generate session protocol types from the canonical schema"
  @moduledoc """
  Reads `priv/session/protocol/jido.session.v1.json` and writes generated
  Elixir and TypeScript protocol types.

      mix jido.protocol.generate
  """

  use Mix.Task

  alias Jido.Console.Session.Protocol
  alias Jido.Console.Session.Protocol.Generator

  @impl Mix.Task
  def run(args) do
    if args != [], do: Mix.raise("usage: mix jido.protocol.generate")

    {:ok, schema} = Protocol.schema()
    paths = Generator.write!(schema)
    Mix.shell().info("Generated #{paths.elixir}")
    Mix.shell().info("Generated #{paths.typescript}")
  end
end
