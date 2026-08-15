defmodule Jido.Console.Release.Homebrew do
  @moduledoc """
  Builds a Homebrew formula for the exact signed native payload.

  The formula does not compile Erlang or Elixir and does not download a
  replacement runtime. It is not published by this module.
  """

  alias Jido.Console.Release.Channel

  @revision 1

  @doc "Returns the formula revision used for the v0.1 support claim."
  @spec revision() :: pos_integer()
  def revision, do: @revision

  @doc "Renders a formula that pins the payload archive and checksum."
  @spec formula(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def formula(payload_dir, opts \\ []) do
    archive = Keyword.get_lazy(opts, :archive, fn -> archive_name(payload_dir) end)

    with {:ok, release} <- decode(Path.join(payload_dir, "release.json")),
         {:ok, sha} <- Jido.Console.Release.Payload.checksum(payload_dir, archive) do
      {:ok,
       """
       class Jido < Formula
         desc "Jido Console local coding harness"
         homepage "https://github.com/agentjido/jido_console"
         url "file://#{archive}"
         version "#{release["version"]}"
         sha256 "#{sha}"
         license "#{release["license"] || "Apache-2.0"}"
         revision #{@revision}

         def install
           prefix.install Dir["*"]
         end
       end
       """}
    end
  end

  @doc "Installs through the shared channel lifecycle using the Homebrew cell."
  @spec install(Path.t(), Path.t(), keyword()) :: {:ok, Channel.install()} | {:error, term()}
  def install(payload_dir, prefix, opts \\ []) do
    with {:ok, text} <- formula(payload_dir, opts),
         :ok <- reject_build_steps(text) do
      Channel.install(:homebrew, payload_dir, prefix, opts)
    end
  end

  defp reject_build_steps(text) do
    if String.contains?(text, ["system \"mix", "system \"erl", "curl ", "wget "]) do
      {:error, :homebrew_builds_from_source}
    else
      :ok
    end
  end

  defp archive_name(directory) do
    case Path.wildcard(Path.join(directory, "*.tar.gz")) do
      [archive] -> Path.basename(archive)
      _other -> "missing.tar.gz"
    end
  end

  defp decode(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end
end
