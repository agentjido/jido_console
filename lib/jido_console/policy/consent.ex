defmodule Jido.Console.Policy.Consent do
  @moduledoc """
  Applies a boundary-changing fallback only after exact, redacted consent.

  Consent is bound to the current and proposed provider, data boundary, cost
  class, and capability. A mismatched, stale, or repeated grant cannot apply a
  different fallback. Rejection leaves the current selection unchanged.
  """

  alias Jido.Console.Digest
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.Redaction

  @fields [:provider, :model, :data_boundary, :cost_class, :capability]
  @boundaries [:provider, :data_boundary, :cost_class, :capability]

  @type request :: %{
          id: String.t(),
          current: map(),
          proposed: map(),
          changes: [String.t()],
          reason: String.t(),
          consumed: boolean()
        }
  @type grant :: %{
          id: String.t(),
          response: :accept | :reject,
          proposed: map(),
          request: request()
        }

  @doc "Builds a consent request or reports that no consent is required."
  @spec request(map(), map(), keyword()) :: {:ok, request()} | {:ok, :not_required} | {:error, term()}
  def request(current, proposed, opts \\ []) when is_map(current) and is_map(proposed) do
    current = normalize(current)
    proposed = normalize(proposed)

    case Preflight.check(
           Keyword.merge(opts,
             provider: Map.get(proposed, :provider, Map.get(current, :provider)),
             model: Map.get(proposed, :model, Map.get(current, :model)),
             current: current,
             fallback: proposed
           )
         ) do
      {:ok, _decision} ->
        {:ok, :not_required}

      {:error, %{outcome: :consent_required} = decision} ->
        {:ok, build_request(current, proposed, decision)}

      {:error, decision} ->
        {:error, decision}
    end
  end

  @doc "Records an accept or reject for the exact presented request."
  @spec decide(request(), :accept | :reject, String.t()) :: {:ok, grant()} | {:error, term()}
  def decide(%{consumed: true}, _response, _presented_id), do: {:error, :consent_consumed}

  def decide(%{id: id}, _response, presented_id) when id != presented_id do
    {:error, :consent_mismatch}
  end

  def decide(request, response, _presented_id) when response in [:accept, :reject] do
    {:ok,
     %{
       id: request.id,
       response: response,
       proposed: request.proposed,
       request: %{request | consumed: true}
     }}
  end

  def decide(_request, _response, _presented_id), do: {:error, :invalid_consent_response}

  @doc "Applies an accepted grant or leaves the selection unchanged on reject."
  @spec apply_grant(map(), grant()) :: {:ok, map()} | {:error, term()}
  def apply_grant(selection, %{response: :reject}) when is_map(selection), do: {:ok, selection}

  def apply_grant(selection, %{response: :accept, proposed: proposed}) when is_map(selection) do
    {:ok, Map.merge(selection, Map.take(proposed, @boundaries ++ [:provider, :model]))}
  end

  def apply_grant(_selection, _grant), do: {:error, :invalid_consent_grant}

  @doc "Formats a redacted consent request for CLI, TUI, and automation."
  @spec format_request(request()) :: String.t()
  def format_request(request) do
    current = format_boundary(request.current)
    proposed = format_boundary(request.proposed)
    changes = Enum.join(request.changes, ", ")

    Redaction.redact("""
    consent.id: #{request.id}
    consent.required: true
    consent.changes: #{changes}
    consent.current: #{current}
    consent.proposed: #{proposed}
    consent.reason: #{request.reason}
    """)
  end

  defp build_request(current, proposed, decision) do
    payload = %{
      current: public(current),
      proposed: public(proposed),
      changes: Preflight.boundary_changes(current, proposed)
    }

    %{
      id: digest(payload),
      current: payload.current,
      proposed: payload.proposed,
      changes: payload.changes,
      reason: Redaction.redact(decision.reason),
      consumed: false
    }
  end

  defp normalize(map) do
    Map.new(@fields, fn key ->
      {key, Map.get(map, key, Map.get(map, Atom.to_string(key)))}
    end)
  end

  defp public(map), do: Map.new(@fields, fn key -> {key, Map.get(map, key)} end)

  defp format_boundary(map) do
    Enum.map_join([:model | @boundaries], " ", fn key ->
      "#{key}=#{Map.get(map, key) || "unset"}"
    end)
  end

  defp digest(payload), do: payload |> :erlang.term_to_binary() |> Digest.hex() |> binary_part(0, 16)
end
