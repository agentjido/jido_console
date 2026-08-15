defmodule Jido.Console.Session.Jidoka do
  @moduledoc """
  Documented Console facade over the approved Milestone 2 Jidoka contracts.

  Console source uses this module for ordered event validation, portable
  projection, and request-handle semantics. It does not call private Jidoka
  runtime, adapter, or execution modules.
  """

  alias Jidoka.Event
  alias Jidoka.Event.Order

  @doc "Validates one ordered Jidoka request stream."
  @spec validate_events([Event.t()]) :: :ok | {:error, term()}
  def validate_events(events), do: Order.validate(events)

  @doc "Projects events through the documented Jidoka root facade."
  @spec project_events([Event.t()] | Event.t()) :: {:ok, term()} | {:error, term()}
  def project_events(events), do: Jidoka.project_events(events)

  @doc "Awaits a public Jidoka request handle."
  @spec await(term(), keyword()) :: term()
  def await(request, opts \\ []), do: Jidoka.await(request, opts)

  @doc "Cancels a public Jidoka request handle."
  @spec cancel(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def cancel(request, opts \\ []), do: Jidoka.cancel(request, opts)
end
