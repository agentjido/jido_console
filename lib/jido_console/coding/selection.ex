defmodule Jido.Console.Coding.Selection do
  @moduledoc "Compatibility composition of independent coding-pack and execution-policy IDs."

  alias Jido.Console.Coding.Pack
  alias Jido.Console.ExecutionPolicy

  @default_policy ExecutionPolicy.restricted_id()

  @type t :: %{
          pack_id: String.t() | nil,
          execution_policy_id: String.t(),
          profile_id: String.t()
        }

  @doc "Returns independent coding-pack and canonical execution-policy IDs."
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts) when is_list(opts) do
    with {:ok, pack} <- Pack.resolve(opts),
         {:ok, execution_policy_id} <- policy_input(opts) do
      cond do
        not (is_binary(execution_policy_id) and execution_policy_id != "") ->
          {:error, {:invalid_execution_policy, execution_policy_id}}

        module_name?(execution_policy_id) ->
          {:error, :coding_module_name_forbidden}

        true ->
          {:ok,
           %{
             pack_id: pack.id,
             execution_policy_id: execution_policy_id,
             profile_id: execution_policy_id
           }}
      end
    end
  end

  def resolve(_opts), do: {:error, :invalid_coding_selection_options}

  @deprecated "Use validate_execution_policy/2"
  @doc "Checks a selected policy through a trusted host resolver."
  @spec validate_profile(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_profile(execution_policy_id, opts), do: validate_execution_policy(execution_policy_id, opts)

  @doc "Checks a selected policy through the optional trusted host resolver."
  @spec validate_execution_policy(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_execution_policy(execution_policy_id, opts) do
    with {:ok, resolver} <- resolver(opts) do
      case resolver do
        nil ->
          :ok

        function when is_function(function, 1) ->
          normalize_result(function.(execution_policy_id), execution_policy_id)

        function when is_function(function, 2) ->
          normalize_result(function.(execution_policy_id, []), execution_policy_id)

        module when is_atom(module) ->
          resolve_module(module, execution_policy_id)

        _resolver ->
          {:error, :invalid_execution_policy_resolver}
      end
    end
  end

  defp policy_input(opts) do
    canonical = Keyword.get_values(opts, :execution_policy)
    legacy = Keyword.get_values(opts, :coding_profile)

    cond do
      canonical != [] and legacy != [] ->
        {:error, :conflicting_execution_policy_inputs}

      length(canonical) > 1 or length(legacy) > 1 ->
        {:error, :repeated_execution_policy_input}

      canonical != [] ->
        normalize_policy(hd(canonical))

      legacy != [] ->
        normalize_policy(hd(legacy))

      true ->
        application_policy()
    end
  end

  defp application_policy do
    case ExecutionPolicy.application_proposal() do
      {:ok, nil} -> {:ok, @default_policy}
      {:ok, id} -> {:ok, id}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_policy(id) when is_binary(id) do
    case ExecutionPolicy.normalize_id(id) do
      "" -> {:error, {:invalid_execution_policy, id}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_policy(value), do: {:error, {:invalid_execution_policy, value}}

  defp resolver(opts) do
    canonical = Keyword.get_values(opts, :execution_policy_resolver)
    legacy = Keyword.get_values(opts, :coding_profile_resolver)

    cond do
      canonical != [] and legacy != [] -> {:error, :conflicting_execution_policy_inputs}
      length(canonical) > 1 or length(legacy) > 1 -> {:error, :repeated_execution_policy_resolver_input}
      canonical != [] -> {:ok, hd(canonical)}
      legacy != [] -> {:ok, hd(legacy)}
      true -> application_resolver()
    end
  end

  defp application_resolver do
    canonical = Application.fetch_env(:jido_console, :execution_policy_resolver)
    legacy = Application.fetch_env(:jido_console, :coding_profile_resolver)

    case {canonical, legacy} do
      {{:ok, _value}, {:ok, _legacy}} -> {:error, :conflicting_execution_policy_inputs}
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> {:ok, nil}
    end
  end

  defp resolve_module(module, execution_policy_id) do
    if function_exported?(module, :resolve, 2),
      do: normalize_result(module.resolve(execution_policy_id, []), execution_policy_id),
      else: {:error, :invalid_execution_policy_resolver}
  end

  defp normalize_result({:ok, _record}, _id), do: :ok
  defp normalize_result(:ok, _id), do: :ok

  defp normalize_result({:error, reason}, id),
    do: {:error, {:unknown_execution_policy, id, reason}}

  defp normalize_result(_result, id), do: {:error, {:unknown_execution_policy, id}}

  defp module_name?(value) when is_binary(value),
    do: String.starts_with?(value, ["Elixir.", ":"]) or String.contains?(value, "/")
end
