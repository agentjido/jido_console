defmodule Jido.Console.Auth do
  @moduledoc """
  Resolves provider credentials from declared sources and reports redacted status.

  Declared variable order selects between provider alternatives. For each
  variable, the host environment takes precedence over an explicitly selected
  private environment file. Credential values are never returned from
  diagnostic APIs.
  """

  alias Jido.Console.Credentials
  alias Jido.Console.Home
  alias Jido.Console.Models
  alias Jido.Console.Providers.Redaction

  @sources %{
    "openai" => [%{variable: "OPENAI_API_KEY", required: true}],
    "anthropic" => [%{variable: "ANTHROPIC_API_KEY", required: true}],
    "google" => [
      %{variable: "GEMINI_API_KEY", required: false},
      %{variable: "GOOGLE_API_KEY", required: false}
    ],
    "ollama" => []
  }

  @type status :: %{
          provider: String.t(),
          identity: String.t() | nil,
          state: :present | :missing | :invalid | :not_required,
          source: :host_env | :env_file | :none,
          variable: String.t() | nil,
          reason: String.t()
        }

  @doc "Returns the declared credential source contract."
  @spec sources() :: %{String.t() => [map()]}
  def sources, do: @sources

  @doc "Returns declared source rows for one provider."
  @spec sources_for(String.t()) :: {:ok, [map()]} | {:error, term()}
  def sources_for(provider) when is_binary(provider) do
    case Map.fetch(@sources, provider) do
      {:ok, rows} -> {:ok, rows}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  @doc "Resolves redacted credential status for catalog providers."
  @spec status(keyword()) :: {:ok, [status()]} | {:error, term()}
  def status(opts \\ []) do
    with {:ok, providers} <- providers(opts),
         {:ok, file_env} <- file_env(opts) do
      {:ok, Enum.map(providers, &provider_status(&1, Keyword.put(opts, :resolved_file_env, file_env)))}
    end
  end

  @doc "Returns a redacted doctor report bound to catalog identities."
  @spec doctor(keyword()) :: {:ok, map()} | {:error, term()}
  def doctor(opts \\ []) do
    with {:ok, rows} <- status(opts),
         {:ok, catalog} <- Models.load(opts) do
      {:ok,
       %{
         "schema" => "jido.auth-doctor",
         "schema_version" => 1,
         "catalog_revision" => catalog.revision,
         "providers" => Enum.map(rows, &encode_status/1),
         "home" => home_label(opts)
       }}
    end
  end

  @doc "Formats `jido auth status` output without credential values."
  @spec format_status([status()]) :: String.t()
  def format_status(rows) do
    header = "PROVIDER\tSTATE\tSOURCE\tREASON\n"

    body =
      Enum.map_join(rows, "", fn row ->
        "#{row.provider}\t#{row.state}\t#{row.source}\t#{row.reason}\n"
      end)

    header <> body
  end

  @doc "Formats `jido doctor` output without credential values."
  @spec format_doctor(map()) :: String.t()
  def format_doctor(report) do
    providers =
      Enum.map_join(report["providers"], "", fn row ->
        "  #{row["provider"]}: #{row["state"]} (#{row["source"]}) #{row["reason"]}\n"
      end)

    "jido doctor\ncatalog #{report["catalog_revision"]}\n" <> providers
  end

  @doc "Rejects command arguments that look like credential values."
  @spec reject_credential_args([String.t()]) :: :ok | {:error, term()}
  def reject_credential_args(args) when is_list(args) do
    flagged =
      Enum.filter(args, fn arg ->
        String.starts_with?(arg, ["sk-", "AKIA"]) or
          String.contains?(arg, ["API_KEY=", "api_key=", "token="])
      end)

    if flagged == [], do: :ok, else: {:error, :credential_argument_rejected}
  end

  defp providers(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        {:ok, Map.keys(@sources) |> Enum.sort()}

      provider when is_binary(provider) ->
        with {:ok, _rows} <- sources_for(provider), do: {:ok, [provider]}

      _other ->
        {:error, :invalid_provider}
    end
  end

  defp provider_status(provider, opts) do
    identity = Keyword.get(opts, :identity)
    {state, source, variable, reason} = resolve_state(provider, opts)

    %{
      provider: provider,
      identity: identity,
      state: state,
      source: source,
      variable: variable,
      reason: Redaction.redact(reason)
    }
  end

  defp resolve_state(provider, opts) do
    {:ok, rows} = sources_for(provider)

    cond do
      rows == [] ->
        {:not_required, :none, nil, "no credential is required"}

      match = first_present(rows, opts) ->
        match

      true ->
        names = Enum.map_join(rows, " or ", & &1.variable)
        {:missing, :none, nil, "set #{names} in the host environment or a private env file"}
    end
  end

  defp first_present(rows, opts) do
    host = Keyword.get_lazy(opts, :host_env, &System.get_env/0)
    file_env = Keyword.get(opts, :resolved_file_env, %{})
    variables = Enum.map(rows, & &1.variable)

    case Credentials.resolve(variables, host, file_env) do
      {:ok, %{source: :host_env, variable: variable}} ->
        {:present, :host_env, variable, "host environment #{variable} is set"}

      {:ok, %{source: :env_file, variable: variable}} ->
        {:present, :env_file, variable, "private env file provides #{variable}"}

      :missing ->
        nil
    end
  end

  defp file_env(opts) do
    case Keyword.get(opts, :env_file) do
      path when is_binary(path) -> load_env_file(path)
      _missing -> {:ok, %{}}
    end
  end

  defp load_env_file(path) do
    Credentials.read_private_env_file(path)
  end

  defp encode_status(row) do
    %{
      "provider" => row.provider,
      "identity" => row.identity,
      "state" => Atom.to_string(row.state),
      "source" => Atom.to_string(row.source),
      "variable" => row.variable,
      "reason" => row.reason
    }
  end

  defp home_label(opts) do
    case Home.resolve(opts) do
      {:ok, _home} -> "configured"
      {:error, _reason} -> "unavailable"
    end
  end
end
