defmodule Jido.Console.Models.Commands do
  @moduledoc """
  Command-line model list and show operations.

  Output is stable, redacted, and limited to catalog records.
  """

  alias Jido.Console.Models
  alias Jido.Console.Error
  alias Jido.Console.Models.Catalog
  alias Jido.Console.Providers.Redaction

  @model_origins [:agent_spec, :cli, :api, :tui]

  @doc "Lists declared catalog models."
  @spec list(keyword()) :: {:ok, String.t()} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, entries} <- Models.list(opts) do
      {:ok, format_list(entries)}
    end
  end

  @doc "Shows one catalog model by provider and model identity."
  @spec show(String.t(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def show(provider_or_identity, model \\ nil, opts \\ [])

  def show(identity, nil, opts) when is_binary(identity) do
    with {:ok, provider, model} <- parse_identity(identity) do
      show(provider, model, opts)
    end
  end

  def show(provider, model, opts) when is_binary(provider) and is_binary(model) do
    with {:ok, entry} <- Models.show(provider, model, opts) do
      {:ok, format_show(entry)}
    end
  end

  @doc "Parses `provider:model` or a provider plus model pair."
  @spec parse_identity(String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def parse_identity(identity) when is_binary(identity) do
    case String.split(identity, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:ok, provider, model}
      _other -> {:error, :invalid_model_identity}
    end
  end

  @doc "Resolves and validates the effective model with explicit origin precedence."
  @spec resolve_effective(term(), term(), keyword()) ::
          {:ok, map()} | {:needs_model, map()} | {:error, term()}
  def resolve_effective(agent_model, choices, opts \\ []) do
    with {:ok, choices} <- normalize_choices(choices),
         {:ok, candidate} <- effective_candidate(agent_model, choices),
         {:ok, catalog} <- catalog(opts),
         {:ok, entry} <- Catalog.select(catalog, candidate.id) do
      {:ok, %{id: candidate.id, origin: candidate.origin, entry: entry}}
    else
      {:error, :missing_model} -> model_failure(:missing_model, opts)
      {:error, {:unsupported_model, identity}} -> model_failure({:unsupported_model, identity}, opts)
      {:error, {:unknown_model, identity}} -> model_failure({:unsupported_model, identity}, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns true for a model choice that came from a direct human input."
  @spec direct_origin?(atom()) :: boolean()
  def direct_origin?(origin), do: origin in [:cli, :api, :tui]

  defp normalize_choices(nil), do: {:ok, []}

  defp normalize_choices(%{} = choice), do: normalize_choices([choice])

  defp normalize_choices(choices) when is_list(choices) do
    Enum.reduce_while(choices, {:ok, []}, fn choice, {:ok, normalized} ->
      case normalize_choice(choice) do
        {:ok, choice} -> {:cont, {:ok, [choice | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_choices(_choices), do: {:error, :invalid_model_choices}

  defp normalize_choice(%{id: id, origin: origin}) when is_binary(id) and origin in @model_origins,
    do: {:ok, %{id: String.trim(id), origin: origin}}

  defp normalize_choice(%{"id" => id, "origin" => origin}) when is_binary(id) do
    origin = normalize_origin(origin)

    if origin in @model_origins,
      do: {:ok, %{id: String.trim(id), origin: origin}},
      else: {:error, {:invalid_model_origin, origin}}
  end

  defp normalize_choice(choice), do: {:error, {:invalid_model_choice, choice}}

  defp effective_candidate(agent_model, choices) do
    direct =
      choices
      |> Enum.filter(&direct_origin?(&1.origin))
      |> Enum.with_index()
      |> Enum.max_by(fn {choice, index} -> {origin_rank(choice.origin), index} end, fn -> nil end)

    case direct do
      {%{id: id} = choice, _index} when id != "" -> {:ok, choice}
      {%{id: ""}, _index} -> {:error, :missing_model}
      nil -> agent_candidate(agent_model)
    end
  end

  defp agent_candidate(nil), do: {:error, :missing_model}

  defp agent_candidate(%LLMDB.Model{} = model),
    do: {:ok, %{id: Jidoka.Config.model_ref(model), origin: :agent_spec}}

  defp agent_candidate(identity) when is_binary(identity) and identity != "",
    do: {:ok, %{id: identity, origin: :agent_spec}}

  defp agent_candidate(_model), do: {:error, :missing_model}

  defp catalog(opts) do
    case Keyword.get(opts, :catalog) do
      %{entries: entries} = catalog when is_list(entries) -> {:ok, catalog}
      nil -> Catalog.load(opts)
      _catalog -> {:error, :invalid_model_catalog}
    end
  end

  defp model_failure(reason, opts) do
    if Keyword.get(opts, :interactive?, false) do
      {:needs_model, %{reason: reason}}
    else
      {:error,
       Error.config_error("A supported model is required for this session", %{
         source: :binding_model,
         reason: reason
       })}
    end
  end

  defp normalize_origin(origin) when is_atom(origin), do: origin

  defp normalize_origin(origin) when is_binary(origin) do
    Enum.find(@model_origins, &(Atom.to_string(&1) == origin))
  end

  defp normalize_origin(_origin), do: nil

  defp origin_rank(:tui), do: 3
  defp origin_rank(origin) when origin in [:cli, :api], do: 2
  defp origin_rank(:agent_spec), do: 1

  defp format_list(entries) do
    header = "PROVIDER\tMODEL\tTIER\tEVIDENCE\n"

    rows =
      entries
      |> Enum.sort_by(& &1.identity)
      |> Enum.map_join("", fn entry ->
        "#{entry.provider}\t#{entry.model}\t#{entry.tier}\t#{entry.evidence_id}\n"
      end)

    header <> rows
  end

  defp format_show(entry) when is_map(entry) do
    capabilities =
      entry.capabilities
      |> Enum.sort_by(fn {key, _feature} -> key end)
      |> Enum.map_join("", fn {key, feature} ->
        "capability.#{key}: #{feature.state} #{feature.evidence || "none"}\n"
      end)

    gaps = Enum.map_join(entry.known_gaps, " | ", &Redaction.redact/1)
    metadata = Map.get(entry, :metadata, %{})
    lifecycle = value(metadata, :lifecycle, %{}) || %{}

    """
    identity: #{entry.identity}
    provider: #{entry.provider}
    model: #{entry.model}
    tier: #{entry.tier}
    evidence: #{entry.evidence_id}
    cost.class: #{entry.cost[:class] || entry.cost["class"]}
    cost.input_per_million: #{value(entry.cost, :input, "unknown")}
    cost.output_per_million: #{value(entry.cost, :output, "unknown")}
    limits.context_tokens: #{entry.limits[:context_tokens] || entry.limits["context_tokens"]}
    limits.output_tokens: #{entry.limits[:output_tokens] || entry.limits["output_tokens"]}
    metadata.source: #{value(metadata, :source, :unknown)}
    lifecycle.status: #{value(lifecycle, :status, "active")}
    lifecycle.replacement: #{value(lifecycle, :replacement, "none")}
    known_gaps: #{gaps}
    """ <> capabilities
  end

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
