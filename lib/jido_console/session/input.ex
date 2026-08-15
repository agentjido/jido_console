defmodule Jido.Console.Session.Input do
  @moduledoc """
  Process-lifetime input admission before advisory or coalescing wake-up.

  Accepted input can be lost if the application crashes before Milestone 3.
  """

  alias Jido.Console.Session.Identity

  @states [:accepted, :started, :completed, :rejected, :cancelled]

  @type t :: %{
          identity: Identity.t(),
          text: String.t(),
          status: atom(),
          wakeups: non_neg_integer()
        }

  @doc "Accepts input and assigns an identity before any wake-up is sent."
  @spec admit(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def admit(text, opts) when is_binary(text) do
    with {:ok, identity} <- Identity.new(:input, Keyword.take(opts, [:session_id, :id, :generation])) do
      {:ok, %{identity: identity, text: text, status: :accepted, wakeups: 0}}
    end
  end

  @doc "Records a coalesced wake-up without changing admitted input."
  @spec wakeup(t()) :: t()
  def wakeup(input), do: %{input | wakeups: input.wakeups + 1}

  @doc "Transitions an admitted input."
  @spec transition(t(), atom()) :: {:ok, t()} | {:error, term()}
  def transition(input, status) when status in @states, do: {:ok, %{input | status: status}}
  def transition(_input, status), do: {:error, {:invalid_input_status, status}}

  @doc "Returns the documented process-lifetime limitation."
  @spec crash_limitation() :: String.t()
  def crash_limitation do
    "Accepted input can be lost on an application crash before Milestone 3."
  end
end
