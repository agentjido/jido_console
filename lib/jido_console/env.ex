defmodule Jido.Console.Env do
  @moduledoc "Loads local provider credentials for the CLI host."

  alias Jido.Console.Credentials

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

  @doc "Returns all provider credential variables that the CLI can load."
  @spec provider_keys() :: [String.t()]
  def provider_keys, do: @provider_keys

  @doc "Loads provider credentials from one local `.env` file without overriding the host environment."
  @spec load_provider_credentials(String.t()) :: :ok | {:error, term()}
  def load_provider_credentials(directory \\ File.cwd!()) when is_binary(directory) do
    path = Path.join(Path.expand(directory), ".env")

    host_env = System.get_env()

    case Credentials.read_private_env_file(path) do
      {:ok, file_env} ->
        @provider_keys
        |> Credentials.resolve_all(host_env, file_env)
        |> Map.new(&{&1.variable, &1.value})
        |> System.put_env()

        :ok

      {:error, {:dotenv_stat_failed, ^path, :enoent}} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
