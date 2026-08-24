defmodule Jido.Console.Tui.Selection do
  @moduledoc """
  TUI `/model` and `/profile` selection against the catalog and local policy.
  """

  alias Jido.Console.Error
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.Registry, as: ExecutionPolicyRegistry
  alias Jido.Console.Models.Commands

  @profiles [ExecutionPolicy.restricted_id(), ExecutionPolicy.trusted_id()]
  @model_tiers [:supported, :beta, :available, :unsupported]

  @type t :: %{
          catalog_entries: [map()],
          model: String.t() | nil,
          model_tier: atom() | nil,
          model_locked?: boolean(),
          profile_id: String.t(),
          profile_warning: String.t() | nil
        }

  @doc "Builds the initial selection from CLI options and the catalog."
  @spec init(keyword()) :: t()
  def init(opts \\ []) do
    entries = Keyword.get_lazy(opts, :catalog_entries, fn -> catalog_entries(opts) end)
    {model, tier} = initial_model(Keyword.get(opts, :model), entries)
    {profile_id, warning} = initial_profile(Keyword.get(opts, :coding_profile))

    %{
      catalog_entries: entries,
      model: model,
      model_tier: tier,
      model_locked?: false,
      profile_id: profile_id,
      profile_warning: warning
    }
  end

  @doc "Lists supported and beta models and marks the current model."
  @spec list_models(t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def list_models(selection) do
    with :ok <- validate_catalog(selection.catalog_entries),
         {:ok, models} <- selectable_models(selection) do
      rows =
        Enum.map_join(models, "\n", fn entry ->
          current = if entry.current?, do: " current", else: ""
          "#{entry.identity} #{entry.tier}#{current}"
        end)

      {:ok, "Models:\n" <> rows}
    end
  end

  @doc "Returns valid selectable models in stable identity order for local discovery."
  @spec selectable_models(t() | map()) :: {:ok, [map()]} | {:error, Exception.t()}
  def selectable_models(%{catalog_entries: entries} = selection) when is_list(entries) do
    models =
      entries
      |> Enum.filter(&(valid_entry?(&1) and selectable?(&1)))
      |> Enum.sort_by(& &1.identity)
      |> Enum.uniq_by(& &1.identity)
      |> Enum.map(fn entry ->
        %{
          identity: entry.identity,
          provider: entry.provider,
          model: entry.model,
          tier: entry.tier,
          current?: entry.identity == Map.get(selection, :model)
        }
      end)

    case {entries, models} do
      {[], _models} -> {:error, empty_catalog_error()}
      {_entries, []} -> {:error, invalid_catalog_error()}
      {_entries, models} -> {:ok, models}
    end
  end

  def selectable_models(_selection), do: {:error, invalid_catalog_error()}

  @doc "Resolves one exact selectable model identity from the local catalog."
  @spec resolve_model(String.t(), t()) :: {:ok, map()} | {:error, Exception.t()}
  def resolve_model(identity, selection) when is_binary(identity) do
    with :ok <- validate_catalog(selection.catalog_entries),
         {:ok, provider, model} <- Commands.parse_identity(identity),
         entry when not is_nil(entry) <-
           Enum.find(selection.catalog_entries, fn entry ->
             entry.identity == identity and entry.provider == provider and entry.model == model and
               selectable?(entry)
           end) do
      {:ok, entry}
    else
      {:error, %_{} = error} ->
        {:error, error}

      _other ->
        {:error,
         Error.validation_error("Unavailable model #{identity}", %{
           identity: identity,
           selectable_tiers: [:supported, :beta]
         })}
    end
  end

  @doc "Returns :ok when the current selection may start a turn."
  @spec admit(t()) :: :ok | {:error, String.t()}
  def admit(selection) do
    with :ok <- model_available(selection) do
      profile_available(selection)
    end
  end

  @doc "Returns the effective-setting title suffix."
  @spec label(t()) :: String.t()
  def label(selection) do
    model = selection.model || "no-model"
    tier = if selection.model_tier, do: Atom.to_string(selection.model_tier), else: "unset"
    warning = if selection.profile_warning, do: " (not a sandbox)", else: ""
    "#{model} #{tier} · #{selection.profile_id}#{warning}"
  end

  @doc "Returns the allowed local profiles."
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

  @doc "Lists the existing profile compatibility options."
  @spec list_profiles() :: String.t()
  def list_profiles, do: "Profiles:\n" <> Enum.join(@profiles, "\n")

  @doc "Returns compatibility feedback for one profile identity."
  @spec profile_notice(String.t()) :: String.t()
  def profile_notice(profile_id) do
    case resolve_profile(profile_id) do
      {:ok, policy} ->
        notice = "Start a new thread to use profile #{policy.execution_policy_id}."
        if policy.warning, do: notice <> " " <> policy.warning, else: notice

      {:error, _reason} ->
        "Unavailable profile #{profile_id}"
    end
  end

  defp catalog_entries(opts) do
    opts
    |> Keyword.get(:model_policy, Application.get_env(:jido_console, :model_policy, []))
    |> policy_entries()
  end

  defp policy_entries(policies) when is_list(policies) do
    policies
    |> Enum.reduce_while([], fn policy, entries ->
      case policy_entry(policy) do
        {:ok, entry} -> {:cont, [entry | entries]}
        :error -> {:halt, []}
      end
    end)
    |> Enum.reverse()
  end

  defp policy_entries(_policies), do: []

  defp policy_entry(policy) when is_map(policy) do
    identity = Map.get(policy, :identity, Map.get(policy, "identity"))
    tier = Map.get(policy, :tier, Map.get(policy, "tier"))

    with true <- is_binary(identity),
         true <- tier in @model_tiers,
         [provider, model] when provider != "" and model != "" <-
           String.split(identity, ":", parts: 2) do
      {:ok, %{identity: identity, provider: provider, model: model, tier: tier}}
    else
      _other -> :error
    end
  end

  defp policy_entry(_policy), do: :error

  defp initial_model(nil, entries) when is_list(entries) do
    case Enum.find(entries, &(valid_entry?(&1) and Map.get(&1, :tier) == :supported)) do
      nil -> {nil, nil}
      entry -> {Map.get(entry, :identity), Map.get(entry, :tier)}
    end
  end

  defp initial_model(nil, _entries), do: {nil, nil}

  defp initial_model(identity, entries) when is_binary(identity) and is_list(entries) do
    case resolve_identity(identity, entries) do
      {:ok, entry} -> {entry.identity, entry.tier}
      :error -> {identity, nil}
    end
  end

  defp initial_model(identity, _entries) when is_binary(identity), do: {identity, nil}

  defp initial_profile(nil), do: {ExecutionPolicy.restricted_id(), nil}

  defp initial_profile(profile_id) when is_binary(profile_id) do
    case resolve_profile(profile_id) do
      {:ok, policy} -> {policy.execution_policy_id, policy.warning}
      {:error, _reason} -> {profile_id, nil}
    end
  end

  defp resolve_identity(token, entries) do
    identity =
      case Commands.parse_identity(token) do
        {:ok, provider, model} -> provider <> ":" <> model
        {:error, _reason} -> token
      end

    case Enum.find(entries, &(valid_entry?(&1) and Map.get(&1, :identity) == identity)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp find_model(%{catalog_entries: entries}, identity) when is_list(entries) do
    Enum.find(entries, &(is_map(&1) and Map.get(&1, :identity) == identity))
  end

  defp find_model(_selection, _identity), do: nil

  defp validate_catalog([]), do: {:error, empty_catalog_error()}

  defp validate_catalog(entries) when is_list(entries) do
    if Enum.all?(entries, &valid_entry?/1) and Enum.any?(entries, &selectable?/1) do
      :ok
    else
      {:error, invalid_catalog_error()}
    end
  end

  defp validate_catalog(_entries), do: {:error, invalid_catalog_error()}

  defp empty_catalog_error,
    do: Error.config_error("Model catalog is empty", %{source: :model_catalog})

  defp invalid_catalog_error,
    do: Error.config_error("Model catalog is invalid", %{source: :model_catalog})

  defp valid_entry?(entry) when is_map(entry) do
    identity = Map.get(entry, :identity)
    provider = Map.get(entry, :provider)
    model = Map.get(entry, :model)

    Enum.all?([identity, provider, model], &(is_binary(&1) and String.valid?(&1))) and
      Map.get(entry, :tier) in @model_tiers and identity == provider <> ":" <> model
  end

  defp valid_entry?(_entry), do: false
  defp selectable?(entry), do: Map.get(entry, :tier) in [:supported, :beta]

  defp model_available(%{model: nil}), do: {:error, "select a catalog model with /model before starting work"}

  defp model_available(selection) do
    if find_model(selection, selection.model),
      do: :ok,
      else: {:error, "unavailable model #{selection.model}"}
  end

  defp profile_available(selection) do
    case resolve_profile(selection.profile_id) do
      {:ok, _profile} -> :ok
      {:error, _reason} -> {:error, "unavailable profile #{selection.profile_id}"}
    end
  end

  defp resolve_profile(profile_id), do: ExecutionPolicyRegistry.fetch(profile_id)
end
