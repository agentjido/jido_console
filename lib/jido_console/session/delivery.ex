defmodule Jido.Console.Session.Delivery do
  @moduledoc """
  Bounded per-client delivery with acknowledgement and explicit gaps.
  """

  @default_bound 32

  @type t :: %{
          client_id: String.t(),
          session_id: String.t(),
          pending: [map()],
          last_acked: non_neg_integer(),
          bound: pos_integer(),
          gap?: boolean()
        }

  @doc "Starts delivery state for one client."
  @spec new(keyword()) :: t()
  def new(opts) do
    %{
      client_id: Keyword.fetch!(opts, :client_id),
      session_id: Keyword.fetch!(opts, :session_id),
      pending: [],
      last_acked: Keyword.get(opts, :last_acked, 0),
      bound: Keyword.get(opts, :bound, @default_bound),
      gap?: false
    }
  end

  @doc "Offers one update. Unsafe updates are never dropped silently."
  @spec offer(t(), map()) :: {:ok, t(), map() | nil} | {:gap, t(), map()}
  def offer(state, update) do
    sequence = update["sequence"] || get_in(update, ["payload", "sequence"]) || 0
    coalesce? = update["coalesce"] == true

    cond do
      length(state.pending) >= state.bound ->
        gap = %{"type" => "delivery_gap", "last_acknowledged" => state.last_acked, "current_sequence" => sequence}
        {:gap, %{state | pending: [], gap?: true}, gap}

      coalesce? and match?([%{coalesce: true} | _], Enum.reverse(state.pending)) ->
        pending = List.replace_at(state.pending, -1, update)
        {:ok, %{state | pending: pending}, update}

      true ->
        {:ok, %{state | pending: state.pending ++ [update]}, update}
    end
  end

  @doc "Acknowledges one delivered sequence for this client and session."
  @spec ack(t(), String.t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def ack(state, client_id, session_id, sequence) do
    cond do
      client_id != state.client_id or session_id != state.session_id ->
        {:error, :identity_mismatch}

      sequence < state.last_acked ->
        {:error, :stale_ack}

      true ->
        pending = Enum.reject(state.pending, fn update -> seq(update) <= sequence end)
        {:ok, %{state | pending: pending, last_acked: sequence, gap?: false}}
    end
  end

  defp seq(update), do: update["sequence"] || get_in(update, ["payload", "sequence"]) || 0
end
