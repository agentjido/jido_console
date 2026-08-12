import Config

# Git hooks never auto-install. Contributors run `mix install_hooks` explicitly.
config :git_hooks,
  auto_install: false,
  verbose: true,
  hooks: [
    pre_commit: [
      {:mix, "format --check-formatted"},
      {:mix, "credo --min-priority higher"}
    ]
  ]
