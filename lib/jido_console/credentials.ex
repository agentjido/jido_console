defmodule Jido.Console.Credentials do
  @moduledoc """
  Resolves credential variables and reads private environment files.

  Variable order has priority. For each variable, the host environment has
  priority over the private environment file. Callers must not put returned
  values in diagnostics or evidence.
  """

  @type source :: :host_env | :env_file
  @type resolved :: %{
          variable: String.t(),
          source: source(),
          value: String.t()
        }

  @doc "Resolves the first present credential from an ordered variable list."
  @spec resolve([String.t()], map(), map()) :: {:ok, resolved()} | :missing
  def resolve(variables, host_env, file_env)
      when is_list(variables) and is_map(host_env) and is_map(file_env) do
    Enum.find_value(variables, :missing, fn variable ->
      case value_for(variable, host_env, file_env) do
        {:ok, source, value} ->
          {:ok, %{variable: variable, source: source, value: value}}

        :missing ->
          nil
      end
    end)
  end

  @doc "Resolves all present variables without changing their declared order."
  @spec resolve_all([String.t()], map(), map()) :: [resolved()]
  def resolve_all(variables, host_env, file_env)
      when is_list(variables) and is_map(host_env) and is_map(file_env) do
    Enum.flat_map(variables, fn variable ->
      case resolve([variable], host_env, file_env) do
        {:ok, resolved} -> [resolved]
        :missing -> []
      end
    end)
  end

  @doc "Reads one regular environment file that grants no group or other access."
  @spec read_private_env_file(String.t()) :: {:ok, map()} | {:error, term()}
  def read_private_env_file(path) when is_binary(path) do
    with {:ok, %{type: :regular, mode: mode}} <- private_regular_file(path),
         :ok <- private_mode(path, mode) do
      load_env_file(path)
    end
  rescue
    exception -> {:error, {:dotenv_load_failed, exception.__struct__}}
  end

  defp value_for(variable, host_env, file_env) do
    cond do
      present?(Map.get(host_env, variable)) ->
        {:ok, :host_env, Map.fetch!(host_env, variable)}

      present?(Map.get(file_env, variable)) ->
        {:ok, :env_file, Map.fetch!(file_env, variable)}

      true ->
        :missing
    end
  end

  defp private_regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, %{type: type}} -> {:error, {:dotenv_not_regular, path, type}}
      {:error, reason} -> {:error, {:dotenv_stat_failed, path, reason}}
    end
  end

  defp private_mode(path, mode) do
    if Bitwise.band(mode, 0o077) == 0 do
      :ok
    else
      {:error, {:dotenv_permissions_too_open, path}}
    end
  end

  defp load_env_file(path) do
    case Dotenvy.source([%{}, path]) do
      {:ok, env} -> {:ok, env}
      {:error, _reason} -> {:error, {:dotenv_load_failed, :invalid_file}}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
