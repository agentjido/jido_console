# Jido Console

> [!WARNING]
> Jido Console is in active development. It does not have a stable public
> release, installation contract, API, or data format.

Jido Console is a BEAM-native local coding harness built on
[Jidoka](https://github.com/agentjido/jidoka). It provides an interactive
terminal and deterministic automation for agent runs and evaluations.

The product target is Jido Console. The current implementation still uses the
legacy `jido_cli` package, `:jido_cli` application, and `Jido.Cli` namespace.
The first release milestone owns that rename. The user command remains `jido`.

## Current Capabilities

- Start the interactive terminal with `jido`.
- Run one agent input or scenario with `jido run`.
- Run an evaluation suite with `jido eval`.
- Write versioned JSONL results and run artifacts.
- Use the restricted local coding profile during development.
- Build and test a macOS ARM64 release candidate with the local release tools.

## Try Jido Locally

Build the developer executable from the repository root:

```sh
mix deps.get
MIX_ENV=prod mix escript.build
```

Jido reads provider credentials from the environment or from a `.env` file in
the current directory. The `.env` file must not be readable by other users.
For the default model, create the file and add an OpenAI key:

```sh
touch .env
chmod 600 .env
```

```dotenv
OPENAI_API_KEY=replace-me
```

Start with a simple chat session that has no project tools:

```sh
./jido --coding-pack disabled
```

At the `>` prompt, try:

```text
Explain what Jido Console does in three sentences.
```

Press `Enter` to send a prompt. Press `Ctrl-J` to add a line. Press `Ctrl-C` to
cancel a running turn. Press `Esc` to exit.

### Explore The Repository

Start the default read-only coding session from the repository root:

```sh
./jido --project-root "$PWD"
```

This session loads project instructions such as `AGENTS.md`. It can read and
search files, but it cannot change them. Attach an exact file with an `@path`
mention:

```text
Summarize @README.md and identify the main CLI entry point.
```

### Change Files Locally

The local coding profile can read, write, inspect Git, and run the registered
`mix test` check inside the selected project root:

```sh
./jido --coding-profile coding.local --project-root "$PWD"
```

This development profile is for macOS. Its tools have no network access, and
it does not provide a general shell. When the TUI requests review, press `A` to
approve the operation or `D` to deny it. See the
[multi-turn coding guide](guides/multi-turn-coding.md) for its tools, limits,
file mentions, and recovery flow.

### Run One Prompt

Use `jido run` when another program will read the result. Automated commands
write JSONL to standard output. This example selects the included concise
agent and prints only its response text:

```sh
printf '%s\n' 'Explain OTP in one sentence.' |
  ./jido run --agent examples/agents/concise.yml --input - |
  jq -r 'select(.schema == "jido.case-result") | .turns[].response.content'
```

The included agent uses `openai:gpt-4o-mini`. Use `--model PROVIDER:MODEL` to
override its model.

### Run The Example Evaluation

The example evaluation makes live provider requests. It requires both
`OPENAI_API_KEY` and `ANTHROPIC_API_KEY`:

```sh
./jido eval examples/evals/smoke.yml
```

The suite runs two agents, two models, two repeats, and a two-turn scenario.
It can make 16 model turns. Review the suite before you run it so that you
understand its time and provider cost.

## Develop Locally

```sh
mix deps.get
mix jido.check
./jido --help
```

Use `mix precommit` and `mix test --cover` before a pull request. See the
[contribution guide](CONTRIBUTING.md) for dependency and quality rules.

## Roadmap and Work Ownership

The [roadmap guide](ROADMAP.md) links the canonical roadmap, milestone
definitions, change history, and 12-hour ownership policy. Each milestone has
one `milestone.md`. Epics will be generated under the owning milestone.

The roadmap is open for review. Use
[GitHub Discussions](https://github.com/agentjido/jido_console/discussions) for
product and scope changes. Use a scoped implementation issue for code work.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `lib/` | Product code that is compiled in all environments |
| `dev/` | Developer and test-only Mix tasks, release assembly, and acceptance tooling |
| `release/` | Controlled release policy, packaging, and acceptance inputs |
| `rel/` | Source launcher and package overlay files used by the native artifact builder |
| `priv/release/` | Runtime release data loaded through the OTP application private directory |
| `examples/` | Public runnable agent and evaluation examples |
| `roadmap/` | Canonical roadmap, milestone definitions, and roadmap changelog |
| `test/` | Unit, integration, terminal, automation, and release contract tests |

The `release/`, `rel/`, `priv/release/`, and `dev/` directories have different
active roles. The release tools use all four. Controlled fixtures stay under
`release/fixtures/`; `examples/` contains only user-facing samples.

## Jido, Jidoka, and Jido Console

| Project | Role |
| --- | --- |
| [Jido](https://github.com/agentjido/jido) | Elixir framework and core agent building blocks |
| [Jidoka](https://github.com/agentjido/jidoka) | Runtime for sessions, effects, tools, cancellation, and recovery |
| Jido Console | User-facing terminal, automation, and future multi-client control plane |

Jidoka owns agent execution truth. Jido Console owns user-visible session truth.
A renderer or transport does not own either source of truth.

Jido Console collects no usage data or telemetry. Never include credentials in
bug reports, logs, artifacts, examples, or fixtures.

Licensed under Apache-2.0. See [LICENSE](LICENSE).
