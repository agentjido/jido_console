defmodule Jido.Console.Session.Effect do
  @moduledoc """
  Typed command effects independent of any client renderer.
  """

  @outcomes [:accepted, :rejected, :deferred, :failed, :no_effect]
  @authority_fields ~w(permission approval capability principal scope)

  @type t :: %{
          required(:outcome) => atom(),
          required(:command_id) => String.t(),
          required(:session_id) => String.t(),
          optional(:run_id) => String.t(),
          optional(:request_id) => String.t(),
          optional(:provenance) => map(),
          optional(:reason) => String.t(),
          optional(:data) => map()
        }

  @doc "Builds a typed command effect."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Map.new(attrs)

    with {:ok, outcome} <- fetch_outcome(attrs),
         {:ok, command_id} <- fetch_string(attrs, :command_id),
         {:ok, session_id} <- fetch_string(attrs, :session_id),
         :ok <- reject_unknown_authority(attrs) do
      {:ok,
       %{
         outcome: outcome,
         command_id: command_id,
         session_id: session_id,
         run_id: optional(attrs, :run_id),
         request_id: optional(attrs, :request_id),
         provenance: Map.get(attrs, :provenance) || Map.get(attrs, "provenance", %{}),
         reason: optional(attrs, :reason),
         data: Map.get(attrs, :data) || Map.get(attrs, "data", %{})
       }}
    end
  end

  @doc "Returns the supported effect outcomes."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc "Returns a protocol-safe effect envelope."
  @spec to_protocol(t()) :: map()
  def to_protocol(effect) do
    %{
      "family" => "outcome",
      "type" => Atom.to_string(effect.outcome),
      "command_id" => effect.command_id,
      "session_id" => effect.session_id,
      "run_id" => effect.run_id,
      "request_id" => effect.request_id,
      "provenance" => effect.provenance,
      "reason" => effect.reason,
      "data" => effect.data
    }
  end

  defp fetch_outcome(attrs) do
    case attrs[:outcome] || attrs["outcome"] do
      outcome when outcome in @outcomes -> {:ok, outcome}
      "accepted" -> {:ok, :accepted}
      "rejected" -> {:ok, :rejected}
      "deferred" -> {:ok, :deferred}
      "failed" -> {:ok, :failed}
      "no_effect" -> {:ok, :no_effect}
      _other -> {:error, :invalid_effect_outcome}
    end
  end

  defp fetch_string(attrs, key) do
    value = attrs[key] || attrs[Atom.to_string(key)]
    if is_binary(value) and value != "", do: {:ok, value}, else: {:error, {:effect_field_missing, key}}
  end

  defp optional(attrs, key) do
    attrs[key] || attrs[Atom.to_string(key)]
  end

  defp reject_unknown_authority(attrs) do
    data = Map.get(attrs, :data) || Map.get(attrs, "data") || %{}
    leaked = Enum.filter(Map.keys(stringify(data)), &(&1 in @authority_fields))
    if leaked == [], do: :ok, else: {:error, {:unknown_authority_field, leaked}}
  end

  defp stringify(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
