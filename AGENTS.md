# AGENTS.md - jido_cli

## Intent

This directory contains the `jido_cli` Mix package. The executable is `jido`.
It is a terminal and automation harness for the public
[Jidoka](https://github.com/agentjido/jidoka) package. The public module
namespace is `Jido.Cli`.

`jido` has two modes. With no command it starts the interactive terminal UI.
With `run` or `eval` it runs file-based scenarios headless and writes JSONL.

## Working Rules

- Depend on the public `jidoka` Hex package for agent import, sessions,
  execution, and assertions. Do not depend on `jido_eval`.
- Keep agent, scenario, and suite inputs as plain YAML or JSON. They must not
  load Elixir modules.
- Preserve the layering inside `Jido.Cli.Automation`:
  - `Command` parses argv into a validated command;
  - `Loader` validates version-1 documents and resolves relative paths;
  - `Plan` builds the deterministic, digest-keyed run matrix;
  - `Engine` (behaviour) runs one cell; `Engine.Jidoka` is the implementation;
  - `JSONL` is the only writer of stdout and run artifacts.
- One matrix cell gets one fresh Jidoka session. Agent state carries across the
  ordered turns of a cell and never between cells.
- The `jido.case-result` JSONL line is the integration boundary. Do not add
  compare or validate commands to the CLI; downstream tools read the raw JSONL.
- Keep tests deterministic by injecting the engine and IO devices through opts
  (`:engine`, `:automation`, `:output_device`, `:input_device`, `:utc_now`,
  `:monotonic_ms`, `:id_generator`). Do not hit live model providers in tests.
- Exit statuses are stable: `0` pass, `1` failed assertion or execution error,
  `64` usage or configuration error.

## Commands

```sh
mix deps.get
mix format
mix test
MIX_ENV=prod mix escript.build
./jido --version
```

The terminal UI requires Erlang/OTP 28 or newer for raw terminal input. The
escript bundles BEAM dependencies and the `llm_db`, `req_llm`, and
`time_zone_info` priv resources (see `include_priv_for` in `mix.exs`); it still
needs a compatible Erlang/OTP install on the target machine.
