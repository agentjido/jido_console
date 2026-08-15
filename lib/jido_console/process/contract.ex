defmodule Jido.Console.Process.Contract do
  @moduledoc "Defines the owned-process catalog and public record types."

  @statuses [:starting, :ready, :running, :stopping, :stopped, :failed]
  @catalog %{
    interactive: %{
      name: "interactive",
      owner: "tui",
      purpose: "interactive terminal session",
      readiness: "terminal and runtime are ready",
      shutdown: "TUI shutdown through the process supervisor"
    },
    coding_runtime: %{
      name: "coding-runtime",
      owner: "coding",
      purpose: "trusted local coding manager",
      readiness: "execution manager is open",
      shutdown: "coding setup close through the process supervisor"
    }
  }

  @type status :: :starting | :ready | :running | :stopping | :stopped | :failed
  @type kind :: :interactive | :coding_runtime
  @type process_record :: %{
          required(:id) => String.t(),
          required(:kind) => kind(),
          required(:name) => String.t(),
          required(:owner) => String.t(),
          required(:status) => status(),
          required(:readiness) => String.t(),
          optional(:failure) => String.t() | nil
        }

  @doc "Returns the supported process status values."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns the local process ownership and status matrix."
  @spec catalog() :: %{kind() => map()}
  def catalog, do: @catalog

  @doc "Returns one catalog entry."
  @spec spec(kind()) :: map()
  def spec(kind) when is_map_key(@catalog, kind), do: Map.fetch!(@catalog, kind)
end
