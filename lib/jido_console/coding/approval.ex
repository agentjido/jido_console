defmodule Jido.Console.Coding.Approval do
  @moduledoc """
  Binds approval to one effect identity and its normalized parameters.

  An approval is valid only for the reviewed effect, workspace, run, profile,
  file roots, network policy, and process owner. Replay after completion or
  failure is denied. Records never include credential values or raw secrets.
  """

  alias Jido.Console.Digest
  alias Jido.Console.Providers.Redaction

  @sensitive ~w(.env .env.local credentials secrets id_rsa id_ed25519)
  @context_keys [:workspace, :run_id, :profile_id, :roots, :network_policy, :process_owner]

  @type effect :: %{operation: String.t(), path: String.t(), params: map()}
  @type context :: map()
  @type binding :: %{
          id: String.t(),
          operation: String.t(),
          path: String.t(),
          params: map(),
          context: map(),
          status: :pending | :completed | :failed
        }

  @doc "Normalizes one effect before it is bound or authorized."
  @spec normalize(map()) :: {:ok, effect()} | {:error, term()}
  def normalize(effect) when is_map(effect) do
    operation = string_field(effect, :operation)
    path = string_field(effect, :path)
    params = field(effect, :params) || %{}

    if is_binary(operation) and operation != "" and is_binary(path) and path != "" and is_map(params) do
      {:ok,
       %{
         operation: operation,
         path: path,
         params: normalize_params(params)
       }}
    else
      {:error, :invalid_effect}
    end
  end

  def normalize(_effect), do: {:error, :invalid_effect}

  @doc "Returns the stable identity for one normalized effect and context."
  @spec identity(effect(), context()) :: {:ok, String.t()} | {:error, term()}
  def identity(effect, context) when is_map(effect) and is_map(context) do
    with {:ok, effect} <- normalize(effect),
         {:ok, context} <- normalize_context(context) do
      {:ok, digest(%{effect: effect, context: context})}
    end
  end

  @doc "Creates a pending approval binding."
  @spec bind(map(), context()) :: {:ok, binding()} | {:error, term()}
  def bind(effect, context) when is_map(effect) and is_map(context) do
    with {:ok, effect} <- normalize(effect),
         {:ok, context} <- normalize_context(context) do
      {:ok,
       %{
         id: digest(%{effect: effect, context: context}),
         operation: effect.operation,
         path: effect.path,
         params: effect.params,
         context: context,
         status: :pending
       }}
    end
  end

  @doc "Authorizes a presented effect against a pending binding."
  @spec authorize(binding(), map(), context()) :: {:ok, binding()} | {:error, term()}
  def authorize(%{status: status}, _effect, _context) when status != :pending do
    {:error, :approval_replay}
  end

  def authorize(binding, effect, context) do
    with {:ok, id} <- identity(effect, context) do
      if id == binding.id, do: {:ok, binding}, else: {:error, :approval_mismatch}
    end
  end

  @doc "Marks a binding consumed after the effect completes or fails."
  @spec consume(binding(), :completed | :failed) :: {:ok, binding()} | {:error, term()}
  def consume(%{status: :pending} = binding, outcome) when outcome in [:completed, :failed] do
    {:ok, %{binding | status: outcome}}
  end

  def consume(_binding, _outcome), do: {:error, :approval_replay}

  @doc "Formats a redacted approval record."
  @spec format(binding()) :: String.t()
  def format(binding) do
    Redaction.redact("""
    approval.id: #{binding.id}
    approval.status: #{binding.status}
    approval.operation: #{binding.operation}
    approval.path: #{display_path(binding.path)}
    approval.profile: #{binding.context.profile_id}
    approval.network: #{binding.context.network_policy}
    approval.owner: #{binding.context.process_owner}
    """)
  end

  @doc "Returns a user-facing path with sensitive file names removed."
  @spec display_path(String.t()) :: String.t()
  def display_path(path) when is_binary(path) do
    if Path.basename(path) in @sensitive, do: "[redacted]", else: path
  end

  defp normalize_context(context) when is_map(context) do
    normalized =
      Map.new(@context_keys, fn key ->
        {key, field(context, key)}
      end)

    if Enum.any?(@context_keys, &(normalized[&1] in [nil, ""])),
      do: {:error, :invalid_approval_context},
      else: {:ok, normalized}
  end

  defp normalize_params(params) do
    params
    |> Enum.reject(fn {key, _value} -> secret_key?(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), redact_value(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp secret_key?(key) do
    name = key |> to_string() |> String.downcase()
    String.contains?(name, ["secret", "token", "password", "credential", "api_key"])
  end

  defp redact_value(value) when is_binary(value), do: Redaction.redact(value)
  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  defp redact_value(value) when is_map(value), do: normalize_params(value)
  defp redact_value(value), do: value

  defp string_field(map, key) do
    case field(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp digest(value), do: value |> :erlang.term_to_binary() |> Digest.hex()
end
