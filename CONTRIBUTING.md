# Contributing to Jido Console

The current `jido_cli` implementation follows the Jido ecosystem package
quality standards.

- keep library code in `lib/`;
- keep runnable agent and scenario examples in `examples/`;
- keep controlled release fixtures in `release/fixtures/`;
- validate command input through the `Jido.Cli.Automation.Command` Zoi schema;
- normalize user-facing errors through `Jido.Cli.Error`;
- keep automated output as the stable `jido.case-result` JSONL contract.

## Setup

The default dependency is an exact Jidoka commit from GitHub. A clean checkout
does not need a sibling Jidoka repository. Get dependencies from the
`jido_cli` directory:

```bash
mix deps.get
```

To test an unpublished local Jidoka change, set an explicit path only in the
development or test environment:

```bash
JIDO_CLI_JIDOKA_PATH=../jidoka mix deps.get
JIDO_CLI_JIDOKA_PATH=../jidoka mix test
```

Do not set this variable in production, CI, or a release build. The default
GitHub commit and `mix.lock` are the repeatable integration contract.

The CLI also constrains ReqLLM to `~> 1.20.0`, the line tested by Jidoka. Update
Jidoka and its adapter tests first. Then update the immutable Jidoka reference
and ReqLLM lock here. Test both the default Git dependency and the local
`JIDO_CLI_JIDOKA_PATH` workflow. A new ReqLLM minor line requires an explicit
constraint change in both repositories.

CLI source must use the documented Jidoka facades and stable data contracts.
It must not use Jidoka runtime, adapter, execution, or asynchronous task
internals.

No Hex Jidoka release is necessary for current source builds. A future package
release must first select an approved immutable Jidoka package strategy. Do not
publish with a local path dependency or a moving Git branch.

## Quality Gate

Run the package gate before opening a pull request:

```bash
mix precommit
mix test --cover
```

`mix precommit` runs, in order: `format --check-formatted`,
`compile --warnings-as-errors`, `credo`, `dialyzer`, and
`doctor --raise`.

Git hooks never auto-install. Install them explicitly when you want them:

```bash
mix install_hooks
```

## Commit Messages

Use Conventional Commits (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`,
`ci`, `perf`). Release notes are generated from the Git history during release,
so do not edit `CHANGELOG.md` in normal pull requests.
