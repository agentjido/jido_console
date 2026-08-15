defmodule Jido.Console.Session.Recovery do
  @moduledoc """
  Process-lifetime recovery from a delivery gap.

  This is not application-restart recovery or durable resume.
  """

  alias Jido.Console.Session.{Delivery, Reducer, State}

  @doc "Builds an explicit gap message."
  @spec gap(String.t(), non_neg_integer(), non_neg_integer()) :: map()
  def gap(session_id, last_acked, current) do
    %{
      "family" => "event",
      "type" => "delivery_gap",
      "session_id" => session_id,
      "last_acknowledged" => last_acked,
      "current_sequence" => current
    }
  end

  @doc "Recovers a client from a snapshot and optional event suffix."
  @spec recover(State.t(), Delivery.t(), [map()]) :: {:ok, Delivery.t(), State.t()} | {:error, term()}
  def recover(state, delivery, suffix) when is_list(suffix) do
    cond do
      delivery.session_id != state.session_id ->
        {:error, :cross_session_result}

      true ->
        case Reducer.replay(suffix, state) do
          {:ok, recovered} ->
            {:ok, %{delivery | pending: [], last_acked: recovered.sequence, gap?: false}, recovered}

          {:error, _reason} = error ->
            error
        end
    end
  end

  @doc "Limitation recorded for Milestone 3."
  @spec limitation() :: String.t()
  def limitation, do: "Delivery-gap recovery is not application-restart recovery or durable resume."
end
