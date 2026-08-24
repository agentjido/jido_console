defmodule Jido.Console.DefaultAgent do
  @moduledoc "Deprecated compatibility facade for `Jido.Console.Agents.Default`."

  @doc "Returns the compiled default agent specification."
  @deprecated "Use Jido.Console.Agents.Default.spec/0"
  @spec spec() :: Jidoka.Agent.Spec.t()
  defdelegate spec(), to: Jido.Console.Agents.Default

  @doc false
  defdelegate __jidoka_agent__(), to: Jido.Console.Agents.Default

  @doc false
  defdelegate __jidoka_agent_id__(), to: Jido.Console.Agents.Default

  @doc false
  defdelegate __jidoka_tools__(), to: Jido.Console.Agents.Default

  @doc "Runs one turn through the deprecated default-agent facade."
  @deprecated "Use Jido.Console.Agents.Default.run_turn/2"
  @spec run_turn(Jidoka.Turn.Request.input(), keyword()) ::
          {:ok, Jidoka.Turn.Result.t()} | {:hibernate, Jidoka.Snapshot.t()} | {:error, term()}
  def run_turn(input, opts \\ []), do: Jido.Console.Agents.Default.run_turn(input, opts)

  @doc "Runs one text chat through the deprecated default-agent facade."
  @deprecated "Use Jido.Console.Agents.Default.chat/2"
  @spec chat(String.t(), keyword()) ::
          {:ok, String.t()} | {:hibernate, Jidoka.Snapshot.t()} | {:error, term()}
  def chat(input, opts \\ []), do: Jido.Console.Agents.Default.chat(input, opts)

  @doc "Starts the deprecated default-agent facade."
  @deprecated "Use Jido.Console.Agents.Default.start/1"
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts \\ []), do: Jido.Console.Agents.Default.start(opts)

  @doc "Returns a child specification for the deprecated default-agent facade."
  @deprecated "Use Jido.Console.Agents.Default.child_spec/1"
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []), do: Jido.Console.Agents.Default.child_spec(opts)
end
