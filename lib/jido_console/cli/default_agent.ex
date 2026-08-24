defmodule Jido.Console.DefaultAgent do
  @moduledoc "Deprecated compatibility facade for `Jido.Console.Agents.Default`."

  @deprecated "Use Jido.Console.Agents.Default.spec/0"
  defdelegate spec(), to: Jido.Console.Agents.Default

  @doc false
  defdelegate __jidoka_agent__(), to: Jido.Console.Agents.Default

  @doc false
  defdelegate __jidoka_agent_id__(), to: Jido.Console.Agents.Default

  @doc false
  defdelegate __jidoka_tools__(), to: Jido.Console.Agents.Default

  @deprecated "Use Jido.Console.Agents.Default.run_turn/2"
  def run_turn(input, opts \\ []), do: Jido.Console.Agents.Default.run_turn(input, opts)

  @deprecated "Use Jido.Console.Agents.Default.chat/2"
  def chat(input, opts \\ []), do: Jido.Console.Agents.Default.chat(input, opts)

  @deprecated "Use Jido.Console.Agents.Default.start/1"
  def start(opts \\ []), do: Jido.Console.Agents.Default.start(opts)

  @deprecated "Use Jido.Console.Agents.Default.child_spec/1"
  def child_spec(opts \\ []), do: Jido.Console.Agents.Default.child_spec(opts)
end
