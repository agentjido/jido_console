defmodule Jido.Console.Release.Identity do
  @moduledoc "Provides the compiled product and runtime release identity."

  @app :jido_console
  @compiled_version Mix.Project.config() |> Keyword.fetch!(:version)

  @type t :: %{
          product: String.t(),
          package: String.t(),
          version: String.t(),
          jidoka: String.t(),
          elixir: String.t(),
          otp: String.t()
        }

  @doc "Returns the product version embedded from the Mix project at compile time."
  @spec version(keyword()) :: String.t()
  def version(opts \\ []) do
    case Keyword.fetch(opts, :application_get_key) do
      {:ok, application_get_key} ->
        case application_get_key.(@app, :vsn) do
          nil -> raise "compiled jido_console application version is unavailable"
          version -> to_string(version)
        end

      :error ->
        @compiled_version
    end
  end

  @doc "Returns the product and runtime identity."
  @spec current(keyword()) :: t()
  def current(opts \\ []) do
    application_get_key = Keyword.get(opts, :application_get_key, &Application.spec/2)

    %{
      product: "jido",
      package: Atom.to_string(@app),
      version: version(application_get_key: application_get_key),
      jidoka: application_version(:jidoka, application_get_key),
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release))
    }
  end

  defp application_version(application, application_get_key) do
    case application_get_key.(application, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
