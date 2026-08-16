defmodule Jido.Console.Session.Delivery do
  @moduledoc """
  Bounded per-client delivery with acknowledgement and explicit gaps.
  """

  @default_bound 32

  @type open :: %{
          status: :open,
          client_id: String.t(),
          session_id: String.t(),
          pending: [map()],
          last_acked: non_neg_integer(),
          highest_offered: non_neg_integer(),
          bound: pos_integer()
        }

  @type gapped :: %{
          status: :gapped,
          client_id: String.t(),
          session_id: String.t(),
          last_acked: non_neg_integer(),
          current_sequence: non_neg_integer(),
          bound: pos_integer()
        }

  @type t :: open() | gapped()

  @doc "Starts delivery state for one client."
  @spec new(keyword()) :: t()
  def new(opts) do
    %{
      status: :open,
      client_id: Keyword.fetch!(opts, :client_id),
      session_id: Keyword.fetch!(opts, :session_id),
      pending: [],
      last_acked: 0,
      highest_offered: 0,
      bound: Keyword.get(opts, :bound, @default_bound)
    }
  end

  @doc "Offers one update. Unsafe updates are never dropped silently."
  @spec offer(t(), map()) :: {:ok, t(), map() | nil} | {:gap, t(), map() | nil}
  def offer(%{status: :gapped} = state, _update), do: {:gap, state, nil}

  def offer(%{status: :open} = state, update) do
    sequence = seq(update)

    if coalescible?(update) and coalescible_tail?(state.pending) do
      {:ok,
       %{
         state
         | pending: List.replace_at(state.pending, -1, update),
           highest_offered: max(state.highest_offered, sequence)
       }, update}
    else
      offer_or_gap(state, update, sequence)
    end
  end

  defp offer_or_gap(state, update, sequence) do
    if length(state.pending) >= state.bound do
      gap = %{
        "type" => "delivery_gap",
        "last_acknowledged" => state.last_acked,
        "current_sequence" => sequence
      }

      {:gap,
       %{
         status: :gapped,
         client_id: state.client_id,
         session_id: state.session_id,
         last_acked: state.last_acked,
         current_sequence: sequence,
         bound: state.bound
       }, gap}
    else
      {:ok,
       %{
         state
         | pending: state.pending ++ [update],
           highest_offered: max(state.highest_offered, sequence)
       }, update}
    end
  end

  defp coalescible?(update) do
    update["coalesce"] == true or Map.get(update, :coalesce) == true
  end

  defp coalescible_tail?([]), do: false
  defp coalescible_tail?(pending), do: coalescible?(List.last(pending))

  @doc "Acknowledges one delivered sequence for this client and session."
  @spec ack(t(), String.t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def ack(state, client_id, session_id, sequence) do
    cond do
      client_id != state.client_id or session_id != state.session_id ->
        {:error, :identity_mismatch}

      state.status == :gapped ->
        {:error, :delivery_gapped}

      sequence < state.last_acked ->
        {:error, :stale_ack}

      sequence > state.highest_offered ->
        {:error, :future_ack}

      true ->
        pending = Enum.reject(state.pending, fn update -> seq(update) <= sequence end)
        {:ok, %{state | pending: pending, last_acked: sequence}}
    end
  end

  defp seq(update), do: update["sequence"] || get_in(update, ["payload", "sequence"]) || 0
end
