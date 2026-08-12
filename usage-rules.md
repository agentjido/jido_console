# Jido CLI Usage Rules

Use these rules when generating code that invokes or depends on `jido_cli`.

## Commands

- Use `jido run --agent FILE (--input FILE|- | --scenario FILE)` for one
  single-turn or multi-turn automated run.
- Use `jido eval SUITE` to run an evaluation matrix.
- With no command, `jido` starts the interactive terminal UI.
- Automated commands write one `jido.case-result` JSON object per physical line
  to standard output and diagnostics to standard error.

## Files

- Agent files are Jidoka documents (`version: 1`, `agent:`). Do not invent a
  separate agent schema.
- Scenario files declare ordered `turns`. The supported assertions are
  `contains`, `equals`, and `operation_called`, and each assertion applies only
  to its own turn.
- Suite files declare the `agents x models x scenarios x repeats` matrix.

## Contracts

- Exit status `0` is pass, `1` is a failed assertion or execution error, and
  `64` is a usage or configuration error.
- Each matrix cell gets one fresh Jidoka session; agent state never crosses
  cells.
- Keep raw JSONL as the integration boundary. Do not expect `compare` or
  `validate` subcommands; group and compare run directories with an external
  tool.
