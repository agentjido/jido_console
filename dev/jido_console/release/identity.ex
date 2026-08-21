defmodule Jido.Console.Release.Identity do
  @moduledoc "Provides build identity for development release tooling."

  @type t :: %{
          product: String.t(),
          package: String.t(),
          version: String.t(),
          jidoka: String.t(),
          jidoka_ref: String.t(),
          elixir: String.t(),
          otp: String.t()
        }

  @doc "Returns the immutable Jidoka Git source identity."
  @spec jidoka_ref() :: String.t()
  def jidoka_ref, do: Mix.Project.config() |> Keyword.fetch!(:jidoka_ref)

  @doc "Returns the compiled product version."
  @spec version(keyword()) :: String.t()
  def version(opts \\ []) do
    case Keyword.fetch(opts, :application_get_key) do
      {:ok, application_get_key} ->
        case application_get_key.(:jido_console, :vsn) do
          nil -> raise "compiled jido_console application version is unavailable"
          version -> to_string(version)
        end

      :error ->
        Jido.Console.version()
    end
  end

  @doc "Returns the product and runtime identity."
  @spec current(keyword()) :: t()
  def current(opts \\ []) do
    application_get_key = Keyword.get(opts, :application_get_key, &Application.spec/2)

    %{
      product: "jido",
      package: "jido_console",
      version: version(application_get_key: application_get_key),
      jidoka: application_version(:jidoka, application_get_key),
      jidoka_ref: jidoka_ref(),
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
