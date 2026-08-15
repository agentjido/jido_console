import Config

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
