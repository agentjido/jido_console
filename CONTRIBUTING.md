# Contributing To Jido CLI

`jido_cli` follows the Jido ecosystem package quality standards.

- keep library code in `lib/`;
- keep runnable agent and scenario examples in `examples/`;
- validate command input through the `Jido.Cli.Automation.Command` Zoi schema;
- normalize user-facing errors through `Jido.Cli.Error`;
- keep automated output as the stable `jido.case-result` JSONL contract.

## Setup

```bash
mix deps.get
```

## Quality Gate

Run the package gate before opening a pull request:

```bash
mix quality
mix test --cover
```

`mix quality` runs, in order: `format --check-formatted`,
`compile --warnings-as-errors`, `credo --min-priority higher`, `dialyzer`, and
`doctor --raise`.

Git hooks never auto-install. Install them explicitly when you want them:

```bash
mix install_hooks
```

## Commit Messages

Use Conventional Commits (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`,
`ci`, `perf`). Release notes are generated from the Git history during release,
so do not edit `CHANGELOG.md` in normal pull requests.
