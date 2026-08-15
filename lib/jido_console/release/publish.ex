defmodule Jido.Console.Release.Publish do
  @moduledoc """
  Records a v0.1 publication plan without performing production publication.

  Production publication requires a passing M1-E29 decision and the protected
  release workflow. This module never uploads, tags, or publishes packages.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Decision

  @doc "Builds a publication plan from a passing release decision."
  @spec plan(map()) :: {:ok, map()} | {:error, term()}
  def plan(decision) when is_map(decision) do
    if decision["decision"] == "pass" do
      {:ok,
       %{
         "schema" => "jido.release-publish",
         "schema_version" => 1,
         "version" => decision["version"],
         "decision" => decision["decision"],
         "channels" => ["archive", "homebrew", "npm"],
         "published" => false,
         "durable_session_recovery" => false,
         "requires_protected_workflow" => true
       }}
    else
      {:error, :release_decision_not_passed}
    end
  end

  @doc "Records publication status. Never contacts a registry or creates a tag."
  @spec execute(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(plan, opts \\ []) when is_map(plan) do
    cond do
      plan["decision"] != "pass" ->
        {:error, :release_decision_not_passed}

      Keyword.get(opts, :publish, false) == true ->
        {:error, :protected_workflow_required}

      true ->
        {:ok,
         Map.merge(plan, %{
           "published" => false,
           "status" => "held",
           "reason" => "production publication is reserved for the protected workflow",
           "summary" => Redaction.redact("v0.1 publication held")
         })}
    end
  end

  @doc "Creates a plan from the current evidence-only decision."
  @spec from_decision(keyword()) :: {:ok, map()} | {:error, term()}
  def from_decision(opts \\ []) do
    with {:ok, decision} <- Decision.record(opts) do
      plan(decision)
    end
  end
end
