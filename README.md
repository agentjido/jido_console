# Jido CLI

> [!WARNING]
> This project is in active development. It is not a supported production
> release. Commands, data contracts, and internal APIs can change.

`jido_cli` is the terminal and automation client for
[Jidoka](https://github.com/agentjido/jidoka). The executable is `jido`.

This repository is primarily for developers who want to test changes and
submit pull requests. There is no supported package installation or Homebrew
flow yet.

## Scope

The CLI owns:

- command parsing and data-only YAML or JSON input;
- the interactive terminal UI;
- scenario and evaluation-matrix planning;
- JSONL output, artifacts, and exit status;
- local release assembly and acceptance tests.

Jidoka owns agent execution, sessions, effects, cancellation, execution
environments, and runtime state. CLI code must use public Jidoka APIs. It must
not depend on Jidoka internals.

The project does not include a daemon or service. It does not publish, sign,
notarize, or update Homebrew.

## Set up a development checkout

Install the Erlang and Elixir versions in `.tool-versions`, then run:

```sh
mix deps.get
mix test
```

The normal build uses a pinned Jidoka Git commit. To test a local Jidoka
checkout, use an explicit path in development or test only:

```sh
JIDO_CLI_JIDOKA_PATH=../jidoka mix deps.get
JIDO_CLI_JIDOKA_PATH=../jidoka mix test
```

Do not use this override in CI or release builds.

## Run from source

Build the developer executable:

```sh
MIX_ENV=prod mix escript.build
./jido --help
```

To test the terminal UI with a provider, create a private `.env` file:

```sh
cp .env.example .env
chmod 600 .env
./jido
```

Never commit credentials. Tests must not call live providers.

For the current multi-turn local coding path, read
[Multi-Turn Coding Development](guides/multi-turn-coding.md).

## Before you submit a pull request

Read `AGENTS.md` and [CONTRIBUTING.md](CONTRIBUTING.md). Keep the change small
and include tests for changed behavior.

Run the complete gate:

```sh
mix jido.check
```

This command checks locked dependencies, formatting, compilation warnings,
Credo, Dialyzer, documentation, specs, test coverage, generated docs, and the
production escript fast path.

Pull requests must:

- keep agent, scenario, and suite files data-only;
- validate external input with Zoi at the correct boundary;
- preserve `jido.case-result` as the automation JSONL boundary;
- keep status `0` for success, `1` for execution failure, and `64` for usage or
  configuration errors;
- use injected test dependencies and deterministic fixtures;
- use a Conventional Commit title.

If a change affects release code, test a non-publishable local macOS ARM64
candidate:

```sh
mix jido.release --allow-dirty
```

This command writes to `dist/`. It does not publish or update Homebrew.

## Repository layout

```text
lib/jido_cli/cli/       CLI, automation, and TUI code
lib/jido_cli/coding/    Trusted local coding integration
lib/jido_cli/terminal/  Terminal input and rendering adapters
dev/                    Development and local release tasks
test/                   Deterministic tests
examples/               Data-only agents, scenarios, and suites
release/                Local packaging policy and evidence rules
```

Licensed under Apache-2.0. See `LICENSE`.
