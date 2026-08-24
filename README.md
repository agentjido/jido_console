# Jido Console

[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

> [!WARNING]
> Jido Console is in active development. It does not have a stable public
> release, installation contract, API, or data format.

Jido Console is a BEAM-native local coding harness built on
[Jidoka](https://github.com/agentjido/jidoka). It provides an interactive
terminal for supervised coding-agent sessions.

The package, OTP application, and namespace are `jido_console`,
`:jido_console`, and `Jido.Console`. The user command remains `jido`.

## Join the Pre-Launch Review

Jido Console is not ready for adopters. The current public work is to review
the direction, improve the contributor path, and prepare the first milestones.

| Your goal | Start here |
| --- | --- |
| Learn what we are building | Read [Current Capabilities](#current-capabilities). No Elixir setup is required. If the direction interests you, [star the repository](https://github.com/agentjido/jido_console) and [join Discord](https://jido.run/discord). |
| Help as a contributor | Read [CONTRIBUTING.md](CONTRIBUTING.md), then ask in [Help and Q&A](https://github.com/agentjido/jido_console/discussions/categories/help-and-q-a) for a small task that is ready now. |
| Review the product or architecture | Read the [roadmap](ROADMAP.md), then raise one clear question in [Roadmap and design](https://github.com/agentjido/jido_console/discussions/categories/roadmap-and-design). |

The roadmap is proposed, and public implementation issues are not open yet.
Confirm the scope in a Discussion before you change code.

If you use a coding agent, start with this review prompt:

```text
I want to help with the Jido Console pre-launch review. Read @README.md,
@CONTRIBUTING.md, and @ROADMAP.md. Do not change files. Find one small,
useful improvement that matches the current roadmap. Explain the user impact,
the files involved, and the questions that I must confirm with a maintainer.
```

After a maintainer confirms the task, give the agent a narrow implementation
prompt:

```text
Implement only this confirmed Jido Console task: <task>. Read @AGENTS.md and
@CONTRIBUTING.md first. Preserve unrelated changes. Run the checks that apply
to the changed files, then show me the diff and the check results.
```

## Current Capabilities

- Start the interactive terminal with `jido`.
- Use the restricted execution policy by default during development.
- Select compiled, YAML, or JSON agent behavior without changing tool authority.
- Build and test a macOS ARM64 release candidate with the local release tools.

## Developer Preview: Try Jido Locally

This path is for technical testers who want to build the current source. It is
not an installation path or a supported release. You do not need to complete
it to take part in the pre-launch review.

Use Elixir 1.18 or later with a supported Erlang/OTP release. The
interactive terminal requires Erlang/OTP 28 or newer. A live session also
requires a provider API key and can incur provider charges.

Clone the repository, then enter its root directory:

```sh
git clone https://github.com/agentjido/jido_console.git
cd jido_console
```

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

Jido resolves allowlisted models through the packaged LLMDB snapshot. LLMDB
supplies model limits, prices, lifecycle data, and execution metadata. Jido
Console configuration supplies the smaller support allowlist, support tiers,
contract evidence, and known integration gaps. An LLMDB catalog entry alone is
not a Jido Console support claim.

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

The prompt also accepts slash commands. Type `/` to show the command list. Use
`Up` and `Down` to move in the list. Press `Tab` to put the selected value in
the prompt. `Tab` does not run the command. Press `Enter` to submit the command.
Press `Esc` to close an open suggestion list. A later `Esc` uses the normal
exit behavior.

Type `/model `, with a space, to show and filter selectable models. The list
marks the effective model as `current`. The suggestions use local data and are
advisory. The live session owner validates the model when you press `Enter`.
`/provider` is not a command. Filter by provider only after `/model `.

Use `/help` to show the current command list. Use `/model` to show selectable
models and the current model. Before the first prompt is accepted, use an exact
identity to select a model:

```text
/model ollama:llama3.2
```

Model selection applies to the current live session only. It locks after the
first prompt is accepted. See the [Jido Console guide](guides/jido-console.md)
for command behavior and model support tiers.

Jido Console keeps three choices separate:

| Choice | Owns | Does not own |
| --- | --- | --- |
| Agent source | Agent behavior, instructions, and model defaults | Coding tools or host permission |
| Coding pack | Coding tools and workspace context | Process isolation or permission |
| Execution policy | Host permission, limits, and isolation requirements | Agent behavior or tool definitions |

The built-in agent is `builtin:jido`. You can also select one YAML, YML, or
JSON Jidoka agent document:

```sh
./jido --agent ./agents/reviewer.yaml
```

All sources resolve to one `Jidoka.Agent.Spec` before a session can run. A file
agent can request an execution-policy ID. It cannot define a policy, add coding
tools, or grant itself more authority. The restricted policy remains the
automatic default. A broader policy always needs an explicit CLI, API, or TUI
choice.

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

The trusted-workspace execution policy can read, write, inspect Git, and run
the registered `mix test` check inside the selected project root:

```sh
./jido --execution-policy coding.trusted-workspace --project-root "$PWD"
```

This policy is not a sandbox. The current coding tools have no network access,
and they do not provide a general shell. When the TUI requests review, press `A` to
approve the operation or `D` to deny it. See the
[multi-turn coding guide](guides/multi-turn-coding.md) for its tools, limits,
file mentions, and recovery flow.

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
one `milestone.md`. Generated epics live under the owning milestone. Each epic
is delivered in one pull request.

The roadmap is open for review. Use
[GitHub Discussions](https://github.com/agentjido/jido_console/discussions) for
product and scope changes. Public implementation issues are not open yet. Ask
in a Discussion before you start code work.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `lib/` | Product code that is compiled in all environments |
| `dev/` | Developer and test-only Mix tasks, release assembly, and acceptance tooling |
| `release/` | Controlled release policy, packaging, and acceptance inputs |
| `rel/` | Source launcher and package overlay files used by the native artifact builder |
| `roadmap/` | Canonical roadmap, milestone definitions, and roadmap changelog |
| `test/` | Unit, integration, terminal, and release contract tests |

The `release/`, `rel/`, and `dev/` directories have different active roles.
Controlled fixtures stay under `release/fixtures/`. Release tools stay under
`dev/`, and the native launcher stays under `rel/`.

## Jido, Jidoka, and Jido Console

| Project | Role |
| --- | --- |
| [Jido](https://github.com/agentjido/jido) | Elixir framework and core agent building blocks |
| [Jidoka](https://github.com/agentjido/jidoka) | Runtime for sessions, effects, tools, cancellation, and recovery |
| Jido Console | User-facing terminal and session control plane |

Jidoka session data owns durable execution truth. Console thread events own
durable product history. One temporary OTP owner per thread owns the live FIFO,
partial output, and complete revisioned View. A renderer or transport owns none
of these authorities.

Console calls the public product choice an **execution policy**. It maps that
choice to Jidoka's existing `Jidoka.ExecutionEnvironment.SecurityProfile` and
execution-environment contracts. Jidoka keeps its current public names.

One request runs at a time in each thread. Up to 32 later prompts wait in FIFO
order. Different thread IDs can run in parallel. A replacement owner does not
resume old work; it waits for a live Jidoka lease or records interruption after
the lease expires. See [local thread storage](guides/durable-continuity.md) for
the storage and recovery contract.

Jido Console collects no usage data or telemetry. Never include credentials in
bug reports, logs, artifacts, examples, or fixtures.

Licensed under Apache-2.0. See [LICENSE](LICENSE).
