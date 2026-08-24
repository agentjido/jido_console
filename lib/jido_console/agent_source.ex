defmodule Jido.Console.AgentSource do
  @moduledoc "Resolves compiled and local-file agent sources to one host record."

  alias Jido.Console.AgentSource.File, as: SourceFile
  alias Jido.Console.AgentSource.Record
  alias Jido.Console.Digest

  @builtin "builtin:jido"

  @doc "Resolves one supported source into a host-owned base agent record."
  @spec resolve(nil | String.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def resolve(source, opts \\ [])

  def resolve(nil, opts), do: resolve(@builtin, opts)

  def resolve(@builtin, _opts) do
    spec = Jido.Console.Agents.Default.spec()
    projection = Jidoka.project(spec)
    source_bytes = Digest.semantic_bytes(:compiled_agent_source, projection)

    {:ok,
     Record.build(
       base_spec: spec,
       identity: @builtin,
       kind: :builtin,
       format: :compiled,
       byte_size: byte_size(source_bytes),
       digest: Digest.portable(source_bytes),
       base_spec_digest: Digest.semantic(:agent_base_spec, projection),
       agent_id: spec.id,
       label: "Jido"
     )}
  end

  def resolve("builtin:" <> _unknown, _opts), do: {:error, :unknown_builtin_agent}

  def resolve(source, opts) when is_binary(source) and is_list(opts) do
    case source_format(source) do
      {:ok, format} ->
        SourceFile.resolve(source, format, opts)

      :error when source == "" ->
        {:error, :invalid_agent_source}

      :error when byte_size(source) >= 8 and binary_part(source, 0, 8) == "BUILTIN:" ->
        {:error, :invalid_agent_source}

      :error ->
        {:error, :unsupported_agent_source_format}
    end
  end

  def resolve(_source, _opts), do: {:error, :invalid_agent_source}

  defp source_format(source) do
    case source |> Path.extname() |> String.downcase() do
      ".json" -> {:ok, :json}
      extension when extension in [".yaml", ".yml"] -> {:ok, :yaml}
      _extension -> :error
    end
  end
end
