# Contributing To Jido CLI

`jido_cli` follows the Jido ecosystem package quality standards.

- keep library code in `lib/`;
- keep runnable agent and scenario examples in `examples/`;
- validate command input through the `Jido.Cli.Automation.Command` Zoi schema;
- normalize user-facing errors through `Jido.Cli.Error`;
- keep automated output as the stable `jido.case-result` JSONL contract.

## Setup

Development and tests use the public API from the sibling Jidoka checkout. Put
both repositories in the same parent directory:

```text
workspace/
  jido_cli/
  jidoka/
```

Then, get the dependencies from the `jido_cli` directory:

```bash
mix deps.get
```

CLI source must use the documented Jidoka facades and stable data contracts.
It must not use Jidoka runtime, adapter, execution, or asynchronous task
internals.

Before a package release, a maintainer must replace the sibling path dependency
with the approved Jidoka Hex requirement and refresh the Jidoka lock entry. Do
not publish the package with a local path dependency.

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
