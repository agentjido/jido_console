defmodule Jido.Console.Session.Jidoka do
  @moduledoc "Small facade over the approved immutable Jidoka public API."

  alias Jidoka.Event
  alias Jidoka.Event.Order
  alias Jidoka.Session.Data
  alias Jidoka.Snapshot

  @jidoka_ref Mix.Project.config() |> Keyword.fetch!(:jidoka_ref)

  @doc "Returns the immutable Jidoka source reference."
  @spec jidoka_ref() :: String.t()
  def jidoka_ref, do: @jidoka_ref

  @doc "Returns the public Jidoka data-format identity."
  @spec durable_contract() :: map()
  def durable_contract do
    %{
      jidoka_ref: @jidoka_ref,
      jidoka_version: application_version(:jidoka),
      session_schema_version: Data.schema_version(),
      supported_session_schema_versions: Data.supported_schema_versions(),
      snapshot_schema_version: Snapshot.schema_version(),
      supported_snapshot_schema_versions: Snapshot.supported_schema_versions(),
      snapshot_serialization_prefix: Snapshot.serialization_prefix()
    }
  end

  @doc "Returns the public Jidoka event names."
  @spec event_names() :: [atom()]
  def event_names, do: Event.events()

  @doc "Validates one ordered Jidoka event stream."
  @spec validate_events([Event.t()]) :: :ok | {:error, term()}
  def validate_events(events), do: Order.validate(events)

  @doc "Projects Jidoka events through its public root facade."
  @spec project_events([Event.t()] | Event.t()) :: {:ok, term()} | {:error, term()}
  def project_events(events), do: Jidoka.project_events(events)

  defp application_version(application) do
    case Application.spec(application, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
