import Config

capability_keys = [
  :streaming,
  :tools,
  :multi_turn_tools,
  :structured_results,
  :cancellation,
  :timeout,
  :prompt_cache
]

supported_capabilities = fn evidence_id, note, prompt_cache_note ->
  Map.new(capability_keys, fn capability ->
    capability_note = if capability == :prompt_cache, do: prompt_cache_note, else: note
    {capability, %{state: :supported, evidence: evidence_id, note: capability_note}}
  end)
end

unknown_capabilities = fn note, prompt_cache_note ->
  Map.new(capability_keys, fn capability ->
    capability_note = if capability == :prompt_cache, do: prompt_cache_note, else: note
    {capability, %{state: :unknown, evidence: nil, note: capability_note}}
  end)
end

config :llm_db,
  custom: %{
    ollama: [
      name: "Ollama",
      base_url: "http://localhost:11434",
      models: %{
        "llama3.2" => %{capabilities: %{chat: true}}
      }
    ]
  }

config :jido_console,
  model_policy: [
    %{
      identity: "openai:gpt-4.1-mini",
      tier: :supported,
      evidence_id: "harness:openai:gpt-4.1-mini",
      capabilities:
        supported_capabilities.(
          "harness:openai:gpt-4.1-mini",
          "Recorded OpenAI v0.1 contract",
          "Automatic prompt cache; no explicit cache-control API"
        ),
      known_gaps: [
        "Recorded qualification does not call a live OpenAI endpoint",
        "Prompt cache is automatic and not separately configurable"
      ]
    },
    %{
      identity: "anthropic:claude-sonnet-4-20250514",
      tier: :supported,
      evidence_id: "harness:anthropic:claude-sonnet-4-20250514",
      capabilities:
        supported_capabilities.(
          "harness:anthropic:claude-sonnet-4-20250514",
          "Recorded Anthropic v0.1 contract",
          "Explicit prompt cache breakpoints are supported in the recorded contract"
        ),
      known_gaps: [
        "Recorded qualification does not call a live Anthropic endpoint",
        "Prompt-cache TTL follows the provider default"
      ]
    },
    %{
      identity: "google:gemini-2.5-flash",
      tier: :supported,
      evidence_id: "harness:google:gemini-2.5-flash",
      capabilities:
        supported_capabilities.(
          "harness:google:gemini-2.5-flash",
          "Recorded Google Gemini v0.1 contract",
          "Implicit prompt cache in the recorded Gemini contract"
        ),
      known_gaps: [
        "Recorded qualification does not call a live Gemini endpoint",
        "Prompt cache is implicit and not separately configurable"
      ]
    },
    %{
      identity: "ollama:llama3.2",
      tier: :beta,
      evidence_id: "pending:ollama-beta",
      capabilities:
        unknown_capabilities.(
          "Ollama remains beta until its beta contract passes",
          "Ollama prompt-cache behavior is not qualified"
        ),
      known_gaps: ["Local-only beta. Not a v0.1 supported-tier claim."]
    }
  ]

if config_env() == :prod do
  # The escript cannot read archived dependency priv files as file-system paths.
  config :llm_db, compile_embed: true

  config :jido_console,
    execution_profile_resolver: Jido.Console.Release.OfflineProfile
end

if config_env() == :dev do
  config :git_ops,
    mix_project: Jido.Console.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/jido_console",
    manage_mix_version?: true,
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      deps: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end
