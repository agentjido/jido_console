# Jido Console Repository Instructions

## Product State

- Product name: Jido Console.
- User command: `jido`.
- Runtime foundation: Jidoka.
- Current implementation identifiers: package `jido_cli`, OTP application
  `:jido_cli`, and namespace `Jido.Cli`.
- Target identifiers: package `jido_console`, OTP application `:jido_console`,
  and namespace `Jido.Console`.
- Do not mix the target rename into unrelated work. The owning roadmap
  milestone controls that change.

`jido` starts the interactive terminal with no command. `jido run` and
`jido eval` run plain YAML or JSON inputs and write JSONL results.

## Runtime Boundaries

- Depend on the approved immutable Jidoka source. Do not depend on `jido_eval`.
- Use documented Jidoka facades and stable data contracts. Do not use Jidoka
  runtime, adapter, execution, or asynchronous task internals.
- Keep agent, scenario, and suite inputs as data. They must not load Elixir
  modules.
- Validate command input and cross-field rules through
  `Jido.Cli.Automation.Command`. Return its documented reason terms.
- Preserve the automation flow: `Command` parses, `Loader` resolves versioned
  documents, `Plan` builds the digest-keyed matrix, `Engine.Jidoka` runs each
  cell through the `Engine` behavior, and `JSONL` writes outputs.
- Normalize user-facing failures through `Jido.Cli.Error`. Keep rich provider
  and execution failure data in the portable Jidoka error form.
- Keep `Jido.Cli.Automation.JSONL` as the only writer of standard output and
  run artifacts.
- Keep `jido.case-result` as the portable integration boundary.
- Give each evaluation matrix cell one fresh Jidoka session. State can continue
  across ordered turns in one cell, but not between cells.
- Preserve exit statuses: `0` for success, `1` for failed assertion or
  execution, and `64` for usage or configuration failure.

## Source Boundaries

- `lib/` contains product code compiled in all environments.
- `dev/` contains developer and test-only modules. `mix.exs` compiles it only
  in development and test. It owns release assembly, acceptance, and custom Mix
  tasks. Do not move this code into `examples/`.
- `release/` contains controlled release inputs. It owns the license policy and
  the packaging and acceptance fixtures. These files are not public examples.
- `rel/bin/jido` is the native package launcher copied by the artifact builder.
  It is not a sample script.
- `priv/release/offline_fixture.json` is the canonical provider-free replay
  record. Product code loads it through `:code.priv_dir/1`, including in the
  packaged release. Do not add a second copy.
- `examples/` contains only public agent and evaluation examples. Release and
  test fixtures do not belong there.
- `roadmap/` is the canonical roadmap. Each milestone is in
  `roadmap/milestones/<name>/milestone.md`. Generated epics belong under the
  owning milestone. Do not add a separate Markdown backlog.

## Deterministic Tests

- Inject engines, clocks, identifiers, and IO devices through options such as
  `:engine`, `:automation`, `:output_device`, `:input_device`, `:utc_now`,
  `:monotonic_ms`, and `:id_generator`.
- Do not call live model providers in tests.
- Keep terminal tests bounded and make process cleanup explicit.
- Test the final archive for release behavior. A build directory does not prove
  an artifact claim.
- Update fixture consumers in the same change when a controlled fixture moves.
- Preserve unrelated changes in a dirty worktree.

## Commands

```sh
mix deps.get
mix jido.check
mix precommit
mix test --cover
mix docs
MIX_ENV=prod mix escript.build
./jido --version
```

Use `mix jido.release` only for the supported local macOS ARM64 release flow.
It builds and tests a candidate. It does not publish, sign, notarize, or update
Homebrew.

The terminal UI requires Erlang/OTP 28 or newer for raw terminal input. The
developer escript still needs a compatible Erlang/OTP installation. The native
release candidate includes its own runtime.
