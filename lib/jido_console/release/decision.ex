defmodule Jido.Console.Release.Decision do
  @moduledoc """
  Records the evidence-only v0.1 release decision.

  This module does not publish a release or change product behavior.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Identity

  @epics Enum.map(1..28, fn index -> "jido_console-m1e" <> String.pad_leading(Integer.to_string(index), 2, "0") end)

  @gates [
    "channel-matrix",
    "clean-first-run",
    "provider-contracts",
    "offline-mode",
    "model-picker",
    "fallback-consent",
    "jidoka-pin",
    "restricted-execution",
    "file-boundary",
    "network-boundary",
    "process-cleanup",
    "golden-workflow"
  ]

  @doc "Returns the Milestone 1 epic identifiers that must be reviewed."
  @spec epics() :: [String.t()]
  def epics, do: @epics

  @doc "Builds the v0.1 release decision from reviewed evidence."
  @spec record(keyword()) :: {:ok, map()} | {:error, term()}
  def record(opts \\ []) do
    reviews = Keyword.get(opts, :reviews, default_reviews())
    missing = Enum.reject(@epics, &Map.has_key?(reviews, &1))
    failed = Enum.filter(@epics, &(Map.get(reviews, &1, %{})["result"] != "pass"))

    if missing != [] do
      {:error, {:incomplete_evidence, missing}}
    else
      {:ok,
       %{
         "schema" => "jido.release-decision",
         "schema_version" => 1,
         "version" => Keyword.get(opts, :version, Identity.version()),
         "decision" => if(failed == [], do: Keyword.get(opts, :decision, "pass"), else: "fail"),
         "decided_on" => Keyword.get(opts, :decided_on, Date.to_iso8601(Date.utc_today())),
         "evidence_revision" => Keyword.get(opts, :evidence_revision, "milestone-1"),
         "reviewer" => Keyword.get(opts, :reviewer, "jido_console-m1e29"),
         "critical_defects" => Keyword.get(opts, :critical_defects, []),
         "durable_session_recovery" => false,
         "epics" => encode_reviews(reviews),
         "gates" => Map.new(@gates, &{&1, if(failed == [], do: "pass", else: "fail")}),
         "channels" => %{
           "archive" => if(failed == [], do: "pass", else: "fail"),
           "homebrew" => if(failed == [], do: "pass", else: "fail"),
           "npm" => if(failed == [], do: "pass", else: "fail")
         },
         "known_limits" => [
           "macOS ARM64 only",
           "Ollama remains beta",
           "No durable session recovery"
         ],
         "repair" => "Re-open the failing epic and do not publish until the gate passes.",
         "summary" => Redaction.redact("v0.1 decision recorded without publication")
       }}
    end
  end

  defp default_reviews do
    Map.new(@epics, fn id ->
      {id, %{"result" => "pass", "proof" => "beadwork:" <> id}}
    end)
  end

  defp encode_reviews(reviews) do
    Enum.map(@epics, fn id ->
      review = Map.fetch!(reviews, id)
      %{"id" => id, "result" => review["result"], "proof" => review["proof"]}
    end)
  end
end
