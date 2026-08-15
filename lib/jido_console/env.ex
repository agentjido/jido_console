defmodule Jido.Console.Env do
  @moduledoc "Loads local provider credentials for the CLI host."

  @provider_keys ~w(
    ANTHROPIC_API_KEY
    AZURE_OPENAI_API_KEY
    GEMINI_API_KEY
    GOOGLE_API_KEY
    GROQ_API_KEY
    MISTRAL_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    XAI_API_KEY
  )

  @doc "Loads provider credentials from one local `.env` file without overriding the host environment."
  @spec load_provider_credentials(String.t()) :: :ok | {:error, term()}
  def load_provider_credentials(directory \\ File.cwd!()) when is_binary(directory) do
    path = Path.join(Path.expand(directory), ".env")

    if File.regular?(path) do
      with :ok <- secure_file(path),
           {:ok, sourced} <- Dotenvy.source([System.get_env(), path, System.get_env()]) do
        sourced
        |> Map.take(@provider_keys)
        |> Map.reject(fn {_key, value} -> not present?(value) end)
        |> System.put_env()

        :ok
      end
    else
      :ok
    end
  rescue
    exception -> {:error, {:dotenv_load_failed, exception.__struct__}}
  end

  defp secure_file(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, _stat} -> {:error, {:dotenv_permissions_too_open, path}}
      {:error, reason} -> {:error, {:dotenv_stat_failed, path, reason}}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
