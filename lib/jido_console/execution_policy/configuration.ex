defmodule Jido.Console.ExecutionPolicy.Configuration do
  @moduledoc false

  alias Jido.Console.ExecutionPolicy.Definition

  require Logger

  @doc false
  @spec warn_legacy() :: :ok
  def warn_legacy do
    Logger.warning(Definition.legacy_warning())
    :ok
  end

  @doc false
  @spec application_proposal() :: {:ok, String.t() | nil} | {:error, term()}
  def application_proposal do
    canonical = Application.fetch_env(:jido_console, :execution_policy)
    legacy = Application.fetch_env(:jido_console, :coding_profile)

    case {canonical, legacy} do
      {{:ok, _value}, {:ok, _legacy}} ->
        {:error, :conflicting_execution_policy_inputs}

      {{:ok, value}, :error} ->
        normalize_proposal(value)

      {:error, {:ok, value}} ->
        :ok = warn_legacy()
        normalize_proposal(value)

      {:error, :error} ->
        {:ok, nil}
    end
  end

  defp normalize_proposal(value) when is_binary(value) do
    case Definition.normalize_id(value) do
      "" -> {:error, {:invalid_execution_policy_input, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_proposal(nil), do: {:ok, nil}
  defp normalize_proposal(value), do: {:error, {:invalid_execution_policy_input, value}}
end
