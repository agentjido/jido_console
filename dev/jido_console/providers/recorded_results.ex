defmodule Jido.Console.Providers.RecordedResults do
  @moduledoc """
  Owns the development provider-contract result set.

  These rows are test observations. They are not derived from model catalog
  claims. Each row identifies the test and evidence record that produced it.
  """

  alias Jido.Console.Providers.ContractResult

  @contract_version ContractResult.contract_version()

  @results [
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :streaming,
      status: :pass,
      reason: "recorded stream chunks kept their order",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-streaming"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :tools,
      status: :pass,
      reason: "recorded tool call and result matched",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-tools"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :multi_turn_tools,
      status: :pass,
      reason: "recorded tool state continued across turns",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-multi-turn-tools"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :structured_results,
      status: :pass,
      reason: "recorded structured result matched the contract",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-structured-results"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :cancellation,
      status: :pass,
      reason: "recorded cancellation reached a terminal result",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-cancellation"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :timeout,
      status: :pass,
      reason: "recorded timeout reached a bounded terminal result",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-timeout"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :usage,
      status: :pass,
      reason: "recorded usage fields matched the contract",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-usage"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :cost,
      status: :pass,
      reason: "recorded cost fields matched the contract",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-cost"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :prompt_cache,
      status: :pass,
      reason: "recorded automatic prompt-cache behavior matched",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-prompt-cache"
    },
    %{
      identity: "openai:gpt-4.1-mini",
      dimension: :error_normalization,
      status: :pass,
      reason: "recorded provider errors matched the portable form",
      evidence_id: "harness:openai:gpt-4.1-mini",
      test_id: "openai-gpt-4.1-mini-error-normalization"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :streaming,
      status: :pass,
      reason: "recorded stream chunks kept their order",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-streaming"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :tools,
      status: :pass,
      reason: "recorded tool call and result matched",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-tools"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :multi_turn_tools,
      status: :pass,
      reason: "recorded tool state continued across turns",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-multi-turn-tools"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :structured_results,
      status: :pass,
      reason: "recorded structured result matched the contract",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-structured-results"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :cancellation,
      status: :pass,
      reason: "recorded cancellation reached a terminal result",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-cancellation"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :timeout,
      status: :pass,
      reason: "recorded timeout reached a bounded terminal result",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-timeout"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :usage,
      status: :pass,
      reason: "recorded usage fields matched the contract",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-usage"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :cost,
      status: :pass,
      reason: "recorded cost fields matched the contract",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-cost"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :prompt_cache,
      status: :pass,
      reason: "recorded prompt-cache breakpoint behavior matched",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-prompt-cache"
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      dimension: :error_normalization,
      status: :pass,
      reason: "recorded provider errors matched the portable form",
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      test_id: "anthropic-claude-sonnet-4-error-normalization"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :streaming,
      status: :pass,
      reason: "recorded stream chunks kept their order",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-streaming"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :tools,
      status: :pass,
      reason: "recorded tool call and result matched",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-tools"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :multi_turn_tools,
      status: :pass,
      reason: "recorded tool state continued across turns",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-multi-turn-tools"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :structured_results,
      status: :pass,
      reason: "recorded structured result matched the contract",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-structured-results"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :cancellation,
      status: :pass,
      reason: "recorded cancellation reached a terminal result",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-cancellation"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :timeout,
      status: :pass,
      reason: "recorded timeout reached a bounded terminal result",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-timeout"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :usage,
      status: :pass,
      reason: "recorded usage fields matched the contract",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-usage"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :cost,
      status: :pass,
      reason: "recorded cost fields matched the contract",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-cost"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :prompt_cache,
      status: :pass,
      reason: "recorded implicit prompt-cache behavior matched",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-prompt-cache"
    },
    %{
      identity: "google:gemini-2.5-flash",
      dimension: :error_normalization,
      status: :pass,
      reason: "recorded provider errors matched the portable form",
      evidence_id: "harness:google:gemini-2.5-flash",
      test_id: "google-gemini-2.5-flash-error-normalization"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :streaming,
      status: :blocked,
      reason: "the beta contract has no recorded streaming observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-streaming"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :tools,
      status: :blocked,
      reason: "the beta contract has no recorded tool observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-tools"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :multi_turn_tools,
      status: :blocked,
      reason: "the beta contract has no recorded multi-turn tool observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-multi-turn-tools"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :structured_results,
      status: :blocked,
      reason: "the beta contract has no recorded structured-result observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-structured-results"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :cancellation,
      status: :blocked,
      reason: "the beta contract has no recorded cancellation observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-cancellation"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :timeout,
      status: :blocked,
      reason: "the beta contract has no recorded timeout observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-timeout"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :usage,
      status: :blocked,
      reason: "the beta contract has no recorded usage observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-usage"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :cost,
      status: :blocked,
      reason: "the beta contract has no recorded cost observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-cost"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :prompt_cache,
      status: :blocked,
      reason: "the beta contract has no recorded prompt-cache observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-prompt-cache"
    },
    %{
      identity: "ollama:llama3.2",
      dimension: :error_normalization,
      status: :blocked,
      reason: "the beta contract has no recorded error-normalization observation",
      evidence_id: "pending:ollama-beta",
      test_id: "ollama-llama3.2-error-normalization"
    }
  ]

  @doc "Returns the complete recorded provider-contract result set."
  @spec all() :: [map()]
  def all do
    Enum.map(@results, fn result ->
      Map.merge(result, %{contract_version: @contract_version, source_mode: :recorded})
    end)
  end
end
