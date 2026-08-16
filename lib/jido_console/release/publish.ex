defmodule Jido.Console.Release.Publish do
  @moduledoc """
  Records a v0.1 publication plan without performing production publication.

  The validated release decision is the only publication authority. This
  module never uploads, tags, or publishes packages.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Decision

  @doc "Builds a publication plan from a validated passing release decision."
  @spec plan(Decision.t()) :: {:ok, map()} | {:error, term()}
  def plan(%Decision{} = decision) do
    with :ok <- Decision.validate(decision),
         :ok <- require_pass(decision) do
      {:ok,
       %{
         "schema" => "jido.release-publish",
         "schema_version" => 1,
         "version" => Decision.version(decision),
         "decision" => "pass",
         "channels" => ["archive", "homebrew", "npm"],
         "published" => false,
         "durable_session_recovery" => false,
         "requires_protected_workflow" => true
       }}
    end
  end

  def plan(_decision), do: {:error, :invalid_release_decision}

  @doc "Records publication status from a validated decision. Never contacts a registry or creates a tag."
  @spec execute(Decision.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(decision, opts \\ [])

  def execute(%Decision{} = decision, opts) do
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

  def execute(_decision, _opts), do: {:error, :invalid_release_decision}

  defp require_pass(decision) do
    case Decision.status(decision) do
      :pass -> :ok
      status -> {:error, {:release_decision_not_passed, status}}
    end
  end
end
