defmodule Jido.Console.Tui.Selection do
  @moduledoc """
  TUI `/model` and `/profile` selection against the catalog and local policy.
  """

  alias Jido.Console.Coding.Profile
  alias Jido.Console.Models.Commands

  @profiles [Profile.restricted_id(), Profile.trusted_id()]
  @model_tiers [:supported, :beta, :available, :unsupported]

  @type t :: %{
          catalog_entries: [map()],
          model: String.t() | nil,
          model_tier: atom() | nil,
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
      profile_id: profile_id,
      profile_warning: warning
    }
  end

  @doc "Handles a slash command or reports that the prompt is not a command."
  @spec handle(String.t(), t()) :: {:command, t(), String.t()} | :not_command
  def handle(prompt, selection) when is_binary(prompt) do
    case String.split(String.trim(prompt), ~r/\s+/, trim: true) do
      ["/model"] -> {:command, selection, list_models(selection)}
      ["/model" | rest] -> select_model(selection, Enum.join(rest, " "))
      ["/profile"] -> {:command, selection, list_profiles()}
      ["/profile", profile_id] -> select_profile(selection, profile_id)
      ["/" <> _command | _rest] -> {:command, selection, "Unknown command. Use /model or /profile."}
      _other -> :not_command
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

  defp select_model(selection, token) do
    case resolve_identity(token, selection.catalog_entries) do
      {:ok, entry} ->
        next = %{selection | model: entry.identity, model_tier: entry.tier}
        {:command, next, "Selected #{entry.identity} (#{entry.tier})"}

      :error ->
        {:command, selection, "Unavailable model #{token}"}
    end
  end

  defp select_profile(selection, profile_id) do
    case resolve_profile(profile_id) do
      {:ok, profile} ->
        next = %{selection | profile_id: profile.id, profile_warning: profile.warning}
        {:command, next, profile_notice(next)}

      {:error, _reason} ->
        {:command, selection, "Unavailable profile #{profile_id}"}
    end
  end

  defp list_models(selection) do
    rows =
      selection.catalog_entries
      |> Enum.sort_by(& &1.identity)
      |> Enum.map_join("\n", fn entry -> "#{entry.identity} #{entry.tier}" end)

    "Models:\n" <> rows
  end

  defp list_profiles do
    "Profiles:\n" <> Enum.join(@profiles, "\n")
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

  defp profile_notice(%{profile_warning: warning} = selection) when is_binary(warning) and warning != "" do
    "Selected #{selection.profile_id}. #{warning}"
  end

  defp profile_notice(selection), do: "Selected #{selection.profile_id}"

  defp profile_available(selection) do
    case resolve_profile(selection.profile_id) do
      {:ok, _profile} -> :ok
      {:error, _reason} -> {:error, "unavailable profile #{selection.profile_id}"}
    end
  end

  defp resolve_profile(profile_id), do: Profile.resolve(profile_id, coding_profile: profile_id)
end
