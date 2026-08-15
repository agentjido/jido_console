defmodule Jido.Console.Coding.Selection do
  @moduledoc "Validates the trusted coding pack and execution-profile selection."

  alias Jido.Console.Coding.Profile
  alias Jidoka.CodingPack

  @default_pack CodingPack.id()
  @default_profile Profile.restricted_id()

  @type t :: %{pack_id: String.t() | nil, profile_id: String.t() | nil}

  @doc "Returns the selected pack and profile IDs."
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts) do
    pack = Keyword.get(opts, :coding_pack, Application.get_env(:jido_console, :coding_pack, @default_pack))
    profile = Keyword.get(opts, :coding_profile, Application.get_env(:jido_console, :coding_profile, @default_profile))

    cond do
      pack in [false, :disabled, "disabled", nil] -> {:ok, %{pack_id: nil, profile_id: nil}}
      not (is_binary(pack) and pack != "") -> {:error, {:invalid_coding_pack, pack}}
      not (is_binary(profile) and profile != "") -> {:error, {:invalid_execution_profile, profile}}
      module_name?(pack) or module_name?(profile) -> {:error, :coding_module_name_forbidden}
      true -> {:ok, %{pack_id: pack, profile_id: profile}}
    end
  end

  @doc "Checks a selected profile through the optional trusted host resolver."
  @spec validate_profile(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_profile(profile_id, opts) do
    case Keyword.get(opts, :coding_profile_resolver, Application.get_env(:jido_console, :coding_profile_resolver)) do
      nil -> :ok
      resolver when is_function(resolver, 1) -> normalize_profile_result(resolver.(profile_id), profile_id)
      _resolver -> {:error, :invalid_coding_profile_resolver}
    end
  end

  defp normalize_profile_result({:ok, _profile}, _id), do: :ok
  defp normalize_profile_result(:ok, _id), do: :ok
  defp normalize_profile_result({:error, reason}, id), do: {:error, {:unknown_runtime_profile, id, reason}}
  defp normalize_profile_result(_result, id), do: {:error, {:unknown_runtime_profile, id}}

  defp module_name?(value), do: String.starts_with?(value, ["Elixir.", ":"]) or String.contains?(value, "/")
end
