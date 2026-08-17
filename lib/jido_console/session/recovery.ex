defmodule Jido.Console.Session.Recovery do
  @moduledoc """
  Process-lifetime recovery from a delivery gap.

  This is not application-restart recovery or durable resume.
  """

  alias Jido.Console.Session.{Delivery, State}

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

  @doc "Recovers a gapped client from the session owner's current snapshot."
  @spec recover(State.t(), Delivery.t()) :: {:ok, Delivery.t(), State.t()} | {:error, term()}
  def recover(state, delivery) do
    cond do
      delivery.session_id != state.session_id ->
        {:error, :cross_session_result}

      delivery.status != :gapped ->
        {:error, :recovery_not_required}

      true ->
        recovered =
          Delivery.new(
            client_id: delivery.client_id,
            session_id: delivery.session_id,
            attachment_id: delivery.attachment_id,
            baseline: state.sequence,
            limits: delivery.limits,
            token_secret: delivery.secret
          )

        {:ok, recovered, state}
    end
  end

  @doc "Limitation recorded for Milestone 3."
  @spec limitation() :: String.t()
  def limitation, do: "Delivery-gap recovery is not application-restart recovery or durable resume."
end
