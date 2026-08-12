# jido_cli

A small terminal and automation harness for
[Jidoka](https://github.com/agentjido/jidoka). The Mix package is `jido_cli`.
The executable is `jido`.

This package uses Jidoka for agent import, execution, sessions, and deterministic
assertions. It does not use `jido_eval`.

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
```

All relative paths start at the file that contains the path. You can also use a
model entry with `source: agent` to keep the model from each agent file.

## Output contract

Automated commands write one `jido.case-result` JSON object per physical line
to standard output. Diagnostics use standard error. A failed assertion or an
execution error gives exit status 1. A command or configuration error gives
exit status 64.

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
