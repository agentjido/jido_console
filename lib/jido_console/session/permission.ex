defmodule Jido.Console.Session.Permission do
  @moduledoc """
  Exact permission request and response life cycle without polling.
  """

  @decisions [:approved, :denied, :expired, :cancelled, :invalid]

  @type request :: map()
  @type t :: %{pending: %{String.t() => request()}}

  @doc "Returns an empty permission table."
  @spec new() :: t()
  def new, do: %{pending: %{}}

  @doc "Records one permission request."
  @spec request(t(), map()) :: {:ok, t(), request()} | {:error, term()}
  def request(table, attrs) do
    required = ~w(id principal rule control effect session_id run_id request_id scope)a

    if Enum.all?(required, &present?(attrs[&1])) do
      record = Map.new(attrs) |> Map.put(:status, :pending)
      {:ok, %{table | pending: Map.put(table.pending, record.id, record)}, record}
    else
      {:error, :incomplete_permission_request}
    end
  end

  @doc "Applies an exact matching response."
  @spec respond(t(), map()) :: {:ok, t(), atom()} | {:error, term()}
  def respond(table, response) do
    pending = table.pending[response[:id]]

    cond do
      is_nil(pending) ->
        {:error, :stale_result}

      pending.session_id != response[:session_id] ->
        {:error, :cross_session_result}

      pending.principal != response[:principal] ->
        {:error, :cross_principal_result}

      pending.id != response[:id] ->
        {:error, :mismatched_response}

      response[:decision] not in @decisions ->
        {:error, :invalid_permission_decision}

      true ->
        {:ok, %{table | pending: Map.delete(table.pending, pending.id)}, response[:decision]}
    end
  end

  @doc "Expires one pending request through an event, not polling."
  @spec expire(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def expire(table, id) do
    case table.pending[id] do
      nil -> {:error, :stale_result}
      _request -> {:ok, %{table | pending: Map.delete(table.pending, id)}}
    end
  end

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true
end
