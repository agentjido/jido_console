# jido_cli

A small terminal and automation harness for
[Jidoka](https://github.com/agentjido/jidoka). The Mix package is `jido_cli`.
The executable is `jido`.

This package uses Jidoka for agent import, execution, sessions, and deterministic
assertions. It does not use `jido_eval`.

## Installation

`jido` is distributed as a self-contained escript. Build it from source with the
steps in [Build](#build) below, or install a published build through Homebrew as
described in [Homebrew packaging](#homebrew-packaging).

The `jido_cli` Mix package also carries Hex metadata for programs that depend on
the harness programmatically:

```elixir
def deps do
  [
    {:jido_cli, "~> 0.1.0"}
  ]
end
```

## Build

Elixir 1.18 or newer is necessary.

```sh
mix deps.get
MIX_ENV=prod mix escript.build
./jido --version
```

The executable requires a compatible Erlang/OTP installation on the target
computer. It extracts packaged runtime data to a versioned temporary directory
when it starts.

## Interactive use

Set the provider credential for the built-in agent. Then, start the terminal UI:

```sh
export OPENAI_API_KEY=...
./jido
```

The terminal UI requires Erlang/OTP 28 or newer for raw terminal input.
Press Ctrl-C during a turn to request cancellation through Jidoka. If the turn
has already completed, its completed answer stays in the transcript. Press
Ctrl-C or Escape while the UI is idle to exit.

### Default coding setup

Interactive use enables the removable `jido.coding_pack` extension by default.
The trusted default execution-profile ID is `coding.default`. The first-run
setup enables bounded workspace read and search tools. A host can add reviewed
write, shell, Git, and verification ports through trusted configuration. Agent
or project data cannot name an Elixir module, command, adapter, image, mount, or
network rule.

Use a different trusted pack or profile ID, or disable the pack:

```sh
./jido --coding-pack acme.coding_pack --coding-profile restricted
./jido --coding-pack disabled
```

`--project-root DIR` selects the trusted workspace root. A host embedding the
CLI can also set `:coding_pack`, `:coding_profile`, `:project_root`,
`:coding_access`, and bounded `:coding_limits`. Command options take precedence
over application defaults. A replacement pack ID resolves through the same
trusted extension-record and project-trust path as an explicit agent request.
Default tools remain independently replaceable or removable by trusted tool
IDs.

At session start, the CLI loads project instruction files through
`Jidoka.CodingPack`. It shows each loaded relative path and scope in the TUI.
Root instructions load before more specific nested instructions. Instruction
content and SHA-256 provenance enter the same data-only Jidoka context used by
coding operations.

Use `@relative/path` to attach a bounded UTF-8 file to one interactive turn.
Use `\@` for a literal at sign. A unique basename can resolve through bounded
workspace search. An ambiguous, missing, ignored, binary, oversized, denied, or
outside-root mention shows an error and does not submit the turn. File mentions
do not use a shell and cannot bypass workspace ignore or path rules. Automated
scenario input does not use fuzzy file mentions; it must give explicit data.

## Run one input or scenario

Use a text file or standard input for one turn:

```sh
./jido run --agent examples/agents/concise.yml --input prompt.md
printf 'Summarize this text.' | ./jido run --agent examples/agents/concise.yml --input -
```

Use a scenario file for one or more ordered turns:

```sh
./jido run \
  --agent examples/agents/concise.yml \
  --scenario examples/evals/scenarios/project_memory.yml \
  --output .jido/runs/project-memory
```

Each automated cell gets one new Jidoka session. All turns in that cell use the
same session and the same agent state. A different agent, model, scenario, or
trial gets a different session. Thus, data cannot move between matrix cells.

A scenario can put input and context in the YAML file or in a relative file:

```yaml
version: 1
scenario:
  id: project_memory
  context:
    value:
      customer: acme
  turns:
    - id: store
      input:
        text: The project name is Atlas. Confirm that you stored it.
      assertions:
        contains: Atlas
    - id: recall
      input:
        text: What is the project name? Include only the name.
      assertions:
        equals: Atlas
```

The supported assertions are `contains`, `equals`, and `operation_called`.
Assertions on a turn apply only to that turn. An operation call from an earlier
turn cannot pass an assertion on a later turn.

Use `--model PROVIDER:MODEL` to replace the model in one agent file. Use
`--runtime-profile ID` to select a trusted runtime profile that the host
application registered. Scenario and agent files cannot load Elixir modules.

Agent and scenario files can select only a profile ID:

```yaml
agent:
  id: concise
  model: openai:gpt-4o-mini
  execution_profile: restricted
```

```yaml
scenario:
  id: project_memory
  execution_profile: network-disabled
  request:
    input: Remember Atlas.
```

The CLI uses this fixed order: command `--runtime-profile`, scenario profile,
agent profile, suite default, then no profile. A suite default is under
`suite.run.execution_profile`. `--runtime-profile` is also valid for `eval`.

The host must configure `:execution_profile_resolver` with a trusted Jidoka
resolver function or module. The resolver maps the ID to a host-owned security
profile and adapter registration. Agent, scenario, and suite files cannot set
commands, images, mounts, network rules, adapter modules, backend options, or
runtime option maps. Invalid and unknown profiles fail before artifact output
starts and return exit status 64.

For a profiled automation cell, the CLI passes only the resolved public data to
Jidoka. Jidoka owns one environment manager for all ordered turns in that cell.
It acquires and releases transient handles for each turn, and it closes the
environment after completion, error, or cancellation. The CLI does not inspect
or store an adapter handle.

## Run an evaluation suite

An evaluation suite creates this matrix:

`agents x models x scenarios x repeats`

Run the included example:

```sh
export OPENAI_API_KEY=...
export ANTHROPIC_API_KEY=...
./jido eval examples/evals/smoke.yml --output .jido/runs/smoke
```

The suite can set a maximum job count. A job is one complete matrix cell, not
one turn. Turns in a cell always run in order.

```yaml
version: 1
suite:
  id: smoke
  agents:
    - key: concise
      file: ../agents/concise.yml
    - key: explanatory
      file: ../agents/explanatory.yml
  scenarios:
    - scenarios/project_memory.yml
  models:
    - key: openai-mini
      ref: openai:gpt-4o-mini
    - key: claude-haiku
      ref: anthropic:claude-3-5-haiku-latest
  matrix:
    repeats: 2
  run:
    jobs: 4
    execution_profile: restricted
```

All relative paths start at the file that contains the path. You can also use a
model entry with `source: agent` to keep the model from each agent file.

## Output contract

Automated commands write one `jido.case-result` JSON object per physical line
to standard output. Diagnostics use standard error. A failed assertion or an
execution error gives exit status 1. A cancelled run also gives exit status 1.
A command or configuration error gives exit status 64.

The executable changes `SIGTERM` into a cooperative cancellation request. The
run stops the admission of new cells. Each started cell still writes one case
result. A cancelled active cell has execution status `cancelled`. The summary
lists the cell identifiers that did not start in `not_started`. This behavior
also applies when a host injects another cancellation source.

When `--output DIR` or `run.output` is set, the directory must be new or empty.
The command writes:

```text
DIR/
  manifest.json
  results.jsonl
  summary.json
  by-agent/<agent-key>.jsonl
```

Each record has stable run, cell, sequence, agent, scenario, model, and trial
fields. It also has one result for each turn, usage data, assertion results, and
portable error data. Concurrent cells can finish in any order. Use `sequence`
or `cell_id` to align records from separate runs.

Each case has an `execution_environment` value. An unprofiled cell uses only
`{"status":"not_requested"}`. A profiled cell keeps these facts separate:

| Field | Meaning |
| --- | --- |
| `requested` | Profile ID, capability IDs, and a digest of the data-only request |
| `resolved` | Trusted profile ID, profile digest, and registration fingerprint |
| `binding` | Redacted binding fingerprint, revision, and state |
| `confirmed` | Adapter-confirmed backend, isolation, network, workspace, image digest, limits, and checkpoint support |
| `lifecycle` | Confirmed or failed checkpoint, restore, fork, close, and cleanup facts |

The status is `not_requested`, `resolved`, `rejected`, `open_failed`,
`enforced`, `closed`, `close_failed`, or `cleanup_failed`. A request is never
reported as enforced unless Jidoka returns confirmed evidence. Manifest cells
contain only requested and resolved identity facts. Case records contain final
confirmed facts. The same case record is copied to `results.jsonl` and the
matching `by-agent` file.

These fields never contain credentials, commands, host paths, adapter options,
provider handles, resource references, or provider-private metadata. Digests
and fingerprints give stable cross-references without exposing these values.

The CLI validates every case result before it writes the JSONL line. It also
validates the version 1 manifest before it creates the output directory and the
version 1 summary before it writes `summary.json`. The schemas require JSON
data, known status values, and nonnegative counts and times. Process values,
functions, ports, references, and non-string JSON map keys are invalid.

Version 1 producers can add data only in a documented optional field or in an
`extensions` entry. Extension identifiers must have a namespace, such as
`acme.metrics`. Version 1 readers ignore unknown optional fields. They reject a
missing required field or an invalid value. This rule lets a newer producer add
optional data without changing the meaning of an existing field.

The CLI does not include compare or validate commands. Keep the raw JSONL files
as the integration boundary. A benchmark tool can group records by the matrix
fields and compare separate run directories.

## Homebrew packaging

Build artifacts depend on the Erlang/OTP major version. Build one artifact for
each supported platform and OTP combination. Publish a checksum for each
artifact. Install it with an Erlang runtime dependency:

```ruby
depends_on "erlang"

def install
  bin.install "jido"
end
```
