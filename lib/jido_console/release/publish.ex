defmodule Jido.Console.Release.Publish do
  @moduledoc """
  Records a v0.1 publication plan without performing production publication.

  The validated release decision is the only publication authority. This
  module never uploads, tags, or publishes packages.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Decision

  @doc "Builds a publication plan from a validated passing release decision."
  @spec plan(term()) :: {:ok, map()} | {:error, term()}
  def plan(decision) do
    with {:ok, authority} <- Decision.authorize_publication(decision) do
      {:ok,
       %{
         "schema" => "jido.release-publish",
         "schema_version" => 1,
         "version" => authority.version,
         "decision" => authority.decision,
         "channels" => authority.channels,
         "published" => false,
         "durable_session_recovery" => false,
         "requires_protected_workflow" => true
       }}
    end
  end

  @doc "Records publication status from a validated decision. Never contacts a registry or creates a tag."
  @spec execute(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(decision, opts \\ [])

  def execute(decision, opts) do
    with {:ok, plan} <- plan(decision),
         false <- Keyword.get(opts, :publish, false) == true do
      {:ok,
       Map.merge(plan, %{
         "published" => false,
         "status" => "held",
         "reason" => "production publication is reserved for the protected workflow",
         "summary" => Redaction.redact("v0.1 publication held")
       })}
    else
      true -> {:error, :protected_workflow_required}
      {:error, reason} -> {:error, reason}
    end
  end
end
