defmodule Jido.Console.Providers.ContractResult do
  @moduledoc """
  Validates one provider-contract result.

  A result is evidence from one identified test. Catalog claims are not
  accepted as a result source.
  """

  @contract_version "jido.provider-contract.v1"
  @dimensions [
    :streaming,
    :tools,
    :multi_turn_tools,
    :structured_results,
    :cancellation,
    :timeout,
    :usage,
    :cost,
    :prompt_cache,
    :error_normalization
  ]
  @statuses [:pass, :fail, :blocked, :not_applicable]
  @source_modes [:recorded, :live]
  @fields [
    :identity,
    :dimension,
    :contract_version,
    :source_mode,
    :status,
    :reason,
    :evidence_id,
    :test_id
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          identity: String.t(),
          dimension: atom(),
          contract_version: String.t(),
          source_mode: :recorded | :live,
          status: atom(),
          reason: String.t(),
          evidence_id: String.t(),
          test_id: String.t()
        }

  @doc "Returns the provider-contract version."
  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @doc "Returns all required contract dimensions."
  @spec dimensions() :: [atom()]
  def dimensions, do: @dimensions

  @doc "Returns accepted result statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Validates one result from a recorded or live source."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = result), do: result |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- exact_fields(attrs),
         {:ok, identity} <- non_empty_string(attrs, :identity),
         {:ok, dimension} <- enum(attrs, :dimension, @dimensions),
         {:ok, contract_version} <- non_empty_string(attrs, :contract_version),
         {:ok, source_mode} <- enum(attrs, :source_mode, @source_modes),
         {:ok, status} <- enum(attrs, :status, @statuses),
         {:ok, reason} <- non_empty_string(attrs, :reason),
         {:ok, evidence_id} <- non_empty_string(attrs, :evidence_id),
         {:ok, test_id} <- non_empty_string(attrs, :test_id) do
      validate(%__MODULE__{
        identity: identity,
        dimension: dimension,
        contract_version: contract_version,
        source_mode: source_mode,
        status: status,
        reason: reason,
        evidence_id: evidence_id,
        test_id: test_id
      })
    end
  end

  def new(_attrs), do: {:error, :invalid_provider_contract_result}

  @doc "Validates a result set and rejects duplicate dimension evidence."
  @spec validate_many([map()]) :: {:ok, [t()]} | {:error, term()}
  def validate_many(results) when is_list(results) do
    with {:ok, normalized} <- normalize_many(results),
         :ok <- reject_duplicates(normalized) do
      {:ok, normalized}
    end
  end

  def validate_many(_results), do: {:error, :invalid_provider_contract_results}

  defp validate(%__MODULE__{} = result) do
    cond do
      result.contract_version != @contract_version ->
        {:error, {:unsupported_provider_contract_version, result.contract_version}}

      result.dimension not in @dimensions ->
        {:error, {:invalid_provider_contract_dimension, result.dimension}}

      result.status not in @statuses ->
        {:error, {:invalid_provider_contract_status, result.status}}

      result.source_mode not in @source_modes ->
        {:error, {:invalid_provider_contract_source_mode, result.source_mode}}

      Enum.any?([result.identity, result.reason, result.evidence_id, result.test_id], &invalid_string?/1) ->
        {:error, :invalid_provider_contract_result}

      true ->
        {:ok, result}
    end
  end

  defp normalize_many(results) do
    results
    |> Enum.reduce_while([], fn attrs, acc ->
      case new(attrs) do
        {:ok, result} -> {:cont, [result | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      normalized -> {:ok, Enum.reverse(normalized)}
    end
  end

  defp reject_duplicates(results) do
    keys = Enum.map(results, &{&1.identity, &1.dimension})

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _rest] -> {:error, {:duplicate_provider_contract_result, key}}
    end
  end

  defp exact_fields(attrs) do
    normalized_keys = Enum.map(Map.keys(attrs), &normalize_key/1)

    cond do
      Enum.any?(normalized_keys, &is_nil/1) ->
        {:error, :invalid_provider_contract_result_fields}

      Enum.sort(normalized_keys) != Enum.sort(@fields) ->
        {:error, :invalid_provider_contract_result_fields}

      true ->
        :ok
    end
  end

  defp normalize_key(key) when key in @fields, do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@fields, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(_key), do: nil

  defp non_empty_string(attrs, key) do
    case field(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_provider_contract_field, key}}
    end
  end

  defp enum(attrs, key, allowed) do
    value = field(attrs, key)

    cond do
      value in allowed ->
        {:ok, value}

      is_binary(value) ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil -> {:error, {:invalid_provider_contract_field, key}}
          normalized -> {:ok, normalized}
        end

      true ->
        {:error, {:invalid_provider_contract_field, key}}
    end
  end

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp invalid_string?(value), do: not is_binary(value) or value == ""
end
