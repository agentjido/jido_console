defmodule Jido.Console.Session.Cancellation do
  @moduledoc """
  Two-stage cancellation: graceful cancel, then force kill if drain fails.
  """

  alias Jido.Console.Session.Drain

  @type t :: %{
          identity: map(),
          status: :requested | :saving | :cancelled | :force_killed | :failed_cleanup,
          drain: Drain.t()
        }

  @doc "Starts graceful cancellation for exact identities."
  @spec request(map(), Drain.t()) :: t()
  def request(identity, drain) do
    %{identity: identity, status: :requested, drain: Drain.start(drain, identity)}
  end

  @doc "Reports the saving state before cancellation completes."
  @spec saving(t()) :: t()
  def saving(cancellation), do: %{cancellation | status: :saving}

  @doc "Completes cancellation only after exact drain."
  @spec complete(t()) :: {:ok, t()} | {:error, term()}
  def complete(cancellation) do
    if Drain.complete?(cancellation.drain) do
      {:ok, %{cancellation | status: :cancelled}}
    else
      {:error, :drain_incomplete}
    end
  end

  @doc "Force-kills the owned worker tree after graceful drain cannot complete."
  @spec force_kill(t()) :: t()
  def force_kill(%{status: status} = cancellation) when status in [:requested, :saving] do
    %{cancellation | status: :force_killed, drain: Drain.fail(cancellation.drain, cancellation.identity)}
  end

  def force_kill(cancellation), do: cancellation

  @doc "Repeated cancellation for the same work is idempotent."
  @spec request_again(t(), map()) :: t() | {:error, term()}
  def request_again(cancellation, identity) do
    if cancellation.identity.id == identity.id and cancellation.identity.session_id == identity.session_id do
      cancellation
    else
      {:error, :cross_session_result}
    end
  end
end
