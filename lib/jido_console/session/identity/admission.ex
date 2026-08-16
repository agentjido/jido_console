defmodule Jido.Console.Session.Identity.Admission do
  @moduledoc """
  Admits identity-bound results for the current process-lifetime work item.

  A result is accepted only when it matches the live session, kind, identifier,
  and generation. Stale, repeated, and cross-session results are rejected
  before they can resolve current work.
  """

  alias Jido.Console.Session.Identity

  @type t :: %{live: Identity.t(), seen: MapSet.t()}

  @doc "Starts admission for one live identity."
  @spec new(Identity.t()) :: t()
  def new(%{} = live), do: %{live: live, seen: MapSet.new()}

  @doc "Admits one candidate result identity."
  @spec admit(t(), Identity.t()) :: {:ok, t()} | {:error, term()}
  def admit(state, candidate) do
    cond do
      Identity.authority_source?(Map.get(candidate, :owner)) ->
        {:error, :authority_source_rejected}

      Identity.cross_session?(state.live, candidate) ->
        {:error, :cross_session_result}

      Identity.stale?(state.live, candidate) ->
        {:error, :stale_result}

      not Identity.same?(state.live, candidate) ->
        {:error, :identity_mismatch}

      MapSet.member?(state.seen, candidate.id) ->
        {:error, :repeated_result}

      true ->
        {:ok, %{state | seen: MapSet.put(state.seen, candidate.id)}}
    end
  end
end
