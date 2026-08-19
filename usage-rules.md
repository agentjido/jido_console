# Jido Console Usage Rules

Use these rules when generating code that invokes or depends on `jido_console`.

## Commands

- With no command, `jido` starts the interactive terminal UI.

## Files

- Project instructions and coding profiles are host configuration. They do not
  load application modules from project data.

## Contracts

- Exit status `0` is success, `1` is an execution error, and `64` is a usage or
  configuration error.
