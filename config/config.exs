import Config

if config_env() == :prod do
  # The escript cannot read archived dependency priv files as file-system paths.
  config :llm_db, compile_embed: true

  config :jido_cli,
    execution_profile_resolver: Jido.Cli.Release.OfflineProfile
end

if config_env() == :dev do
  config :git_ops,
    mix_project: Jido.Cli.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/mikehostetler/jido_cli",
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
