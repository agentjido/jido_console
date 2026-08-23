defmodule Jido.Console.Tui.Selection do
  @moduledoc """
  TUI `/model` and `/profile` selection against the catalog and local policy.
  """

  alias Jido.Console.Coding.Profile
  alias Jido.Console.Error
  alias Jido.Console.Models.Commands

  @profiles [Profile.restricted_id(), Profile.trusted_id()]
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
    with :ok <- validate_catalog(selection.catalog_entries) do
      rows =
        selection.catalog_entries
        |> Enum.filter(&selectable?/1)
        |> Enum.sort_by(& &1.identity)
        |> Enum.map_join("\n", fn entry ->
          current = if entry.identity == selection.model, do: " current", else: ""
          "#{entry.identity} #{entry.tier}#{current}"
        end)

      {:ok, "Models:\n" <> rows}
    end
  end

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
      {:ok, profile} ->
        notice = "Start a new thread to use profile #{profile.id}."
        if profile.warning, do: notice <> " " <> profile.warning, else: notice

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

  defp initial_model(nil, entries) do
    case Enum.find(entries, &(&1.tier == :supported)) do
      nil -> {nil, nil}
      entry -> {entry.identity, entry.tier}
    end
  end

  defp initial_model(identity, entries) when is_binary(identity) do
    case resolve_identity(identity, entries) do
      {:ok, entry} -> {entry.identity, entry.tier}
      :error -> {identity, nil}
    end
  end

  defp initial_profile(nil), do: {Profile.restricted_id(), nil}

  defp initial_profile(profile_id) when is_binary(profile_id) do
    case resolve_profile(profile_id) do
      {:ok, profile} -> {profile.id, profile.warning}
      {:error, _reason} -> {profile_id, nil}
    end
  end

  defp resolve_identity(token, entries) do
    identity =
      case Commands.parse_identity(token) do
        {:ok, provider, model} -> provider <> ":" <> model
        {:error, _reason} -> token
      end

    case Enum.find(entries, &(&1.identity == identity)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp find_model(selection, identity) do
    Enum.find(selection.catalog_entries, &(&1.identity == identity))
  end

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

  defp resolve_profile(profile_id), do: Profile.resolve(profile_id, coding_profile: profile_id)

  defp validate_catalog([]),
    do: {:error, Error.config_error("Model catalog is empty", %{source: :model_catalog})}

  defp validate_catalog(entries) when is_list(entries) do
    if Enum.all?(entries, &valid_entry?/1) and Enum.any?(entries, &selectable?/1) do
      :ok
    else
      {:error, Error.config_error("Model catalog is invalid", %{source: :model_catalog})}
    end
  end

  defp validate_catalog(_entries),
    do: {:error, Error.config_error("Model catalog is invalid", %{source: :model_catalog})}

  defp valid_entry?(entry) when is_map(entry) do
    is_binary(Map.get(entry, :identity)) and is_binary(Map.get(entry, :provider)) and
      is_binary(Map.get(entry, :model)) and Map.get(entry, :tier) in @model_tiers and
      Map.get(entry, :identity) == Map.get(entry, :provider) <> ":" <> Map.get(entry, :model)
  end

  defp valid_entry?(_entry), do: false
  defp selectable?(entry), do: Map.get(entry, :tier) in [:supported, :beta]
end
