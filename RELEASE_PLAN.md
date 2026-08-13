# Jido CLI Release Plan

## Purpose

This document defines the local release flow for `jido_cli`. The installed
product is **Jido** and the public command is `jido`.

The product identity stays unchanged:

- Mix package: `jido_cli`
- Elixir namespace: `Jido.Cli`
- executable: `jido`
- repository: `jido_cli`

The current goal is one local command that creates a tested macOS ARM64 release
candidate. The output must be ready for a later GitHub upload and Homebrew
formula. This work does not publish an artifact and does not change a Homebrew
repository.

## Release scope

The local release candidate must:

- include a private Erlang/OTP runtime;
- run without Erlang or Elixir on `PATH`;
- provide the full-screen TUI and the `run` and `eval` commands;
- preserve fast help, version, and paint-first startup;
- report one product version from one source;
- contain all required runtime data and native libraries;
- be relocatable after extraction;
- run from a read-only installation directory;
- contain license notices and release metadata;
- have a stable artifact name and SHA-256 checksum;
- include machine-readable build and acceptance evidence.

## Non-goals

The current local release work will not:

- add an independent daemon, local protocol, or operating-system service;
- add `jido daemon` commands;
- create or update a Homebrew formula or tap;
- upload or publish a GitHub release;
- publish a Hex package;
- sign or notarize an artifact;
- build macOS x86-64, Linux, or Windows artifacts;
- use an Erlang runtime from `PATH`;
- provide hot code upgrades.

The package design must not prevent later target, signing, GitHub, or Homebrew
work.

## Product modes

One `jido` executable owns all current user-facing modes:

```text
jido                         Start the interactive TUI
jido run ...                 Run one input or scenario locally
jido eval ...                Run one evaluation suite locally
jido --version               Show the Jido version
```

All modes run in the process that the user starts. There is no independent
daemon or service boundary in this release plan.

## Package architecture

The isolated package contains application code and a target-specific private
OTP runtime:

```text
jido-<version>-darwin-arm64/
├── bin/
│   └── jido
├── libexec/
│   ├── application code
│   └── private OTP runtime
├── LICENSE
├── THIRD_PARTY_NOTICES
└── release.json
```

The local release directory contains the final package outputs:

```text
dist/
├── jido-<version>-darwin-arm64.tar.gz
├── checksums.txt
├── release.json
├── sbom.json                     When supported
├── provenance.json
└── acceptance.json
```

The launcher must resolve all package paths relative to itself. It must always
use the private runtime. It must not inspect or use a system OTP installation.
It must preserve arguments, standard streams, terminal control, signals, and
exit status.

The archive name and root directory are stable Homebrew inputs. The future
formula will need only an immutable download URL, the SHA-256 value, the target,
and the location of `bin/jido`.

## Packaging decision

Use one target-specific Mix release with a private OTP runtime. This is the
selected package method. Use Burrito only if the Mix release has a required
failure that cannot be corrected in the release configuration or launcher. Do
not maintain two package methods.

The launcher must enter the CLI before it starts `:jido_cli` or its dependency
applications. This preserves these startup paths:

- `--help` and `--version` return before credentials and runtime startup;
- the TUI paints its first frame before runtime startup;
- the TUI accepts input while runtime startup continues;
- one submitted prompt waits and runs once when the runtime is ready;
- `run` and `eval` complete runtime startup before they run work.

The feasibility build used the standard release `eval` command to prove the
entry order. The maintained package must use a supported release entry module
and launcher. The public launcher must not contain an `eval` expression.

The production release must build from source with no edit to a compiled
dependency. Resolve the current `llm_db` conflict in source metadata or release
configuration. `llm_db` must not be both a regular application and an included
application.

## Startup benchmark and limits

The macOS ARM64 feasibility test on 2026-08-13 gave these warm-cache results:

| Event | Production escript | OTP release |
|---|---:|---:|
| `--help` or `--version` | 0.83-0.85 s | 0.22-0.23 s |
| First TUI frame | 0.88-0.99 s | 0.25-0.28 s |
| TUI runtime ready | 3.41-3.55 s | 0.86-0.96 s |

The escript was 71 MB. The feasibility release was 217 MB after extraction and
76 MB as a gzip archive. The installed-size increase is accepted for the first
release candidate. The archive-size increase is small and startup is
approximately four times faster.

The final-archive acceptance test must measure 20 warm runs and one cold run.
The warm median must meet these limits:

- `--help` and `--version`: at most 0.50 seconds;
- first TUI frame: at most 0.50 seconds;
- TUI runtime ready: at most 1.25 seconds.

Record the cold result and the 95th percentile. The cold result is not a gate
until there is sufficient machine variance data. A warm regression is a release
blocker unless a reviewed decision changes the limit.

## First target and later targets

The first local end-to-end target is:

| Target | Artifact |
|---|---|
| macOS ARM64 | `jido-<version>-darwin-arm64.tar.gz` |

Later native work can add these targets through the same contract:

| Target | Artifact |
|---|---|
| macOS x86-64 | `jido-<version>-darwin-x64.tar.gz` |
| Linux x86-64 | `jido-<version>-linux-x64.tar.gz` |
| Linux ARM64 | `jido-<version>-linux-arm64.tar.gz` |
| Windows x86-64 | `jido-<version>-windows-x64.zip` |

Do not publish one artifact for multiple targets. OTP and native dependencies
are target-specific.

## Local end-to-end release flow

Provide one repository command for the complete local flow. It can call smaller
tasks, but users must not have to assemble the release by hand.

The command must:

1. Validate the product version, source commit, target, and release inputs.
2. Reject a dirty worktree by default. Permit an explicit development override
   that marks all output as dirty and not publishable.
3. Resolve locked dependencies from a clean checkout.
4. Run formatting, compilation with warnings as errors, static analysis, and
   tests.
5. Audit shipped dependencies and generate third-party notices.
6. Build the production Mix release and supported launcher.
7. Assemble the versioned package directory.
8. Validate required `priv` data, native libraries, permissions, and paths.
9. Generate `release.json`, an SBOM when supported, and provenance.
10. Create the deterministic target archive.
11. Generate the external SHA-256 checksum after the final archive change.
12. Unpack the exact archive bytes into an isolated test directory.
13. Run automated packaged-artifact and startup acceptance.
14. Write `acceptance.json` and print the final artifact paths, version, target,
    and SHA-256 value.

The flow must stop on the first failed gate. It must not publish, tag, sign,
notarize, or edit another repository. A repeated run with the same controlled
inputs must replace only its exact target outputs or fail with a clear message.
It must not leave an ambiguous partial candidate in `dist/`.

## Release metadata

`release.json` must include:

- product and Mix package names;
- product version;
- source commit and dirty state;
- target and artifact name;
- Elixir and OTP versions;
- Jidoka source identity;
- Mix release and launcher versions;
- shipped file digests;
- required runtime-data inventory;
- build time and reproducibility fields;
- signing and notarization state;
- SHA-256 value or an external checksum reference that avoids recursion.

`provenance.json` must identify the local build tool, host target, compiler,
source commit, and release inputs. It must not contain credentials, private
paths, provider values, or other secrets.

The command must show that signing, notarization, upload, and Homebrew are not
complete. An unsigned local candidate must not claim stable public status.

## Automated artifact acceptance

The acceptance harness must use the final archive, not the release build
directory. It must remove Erlang, Elixir, and Mix from `PATH` before it starts
the packaged command.

The final archive must pass:

```sh
jido --version
jido --help
jido run --help
jido eval --help
```

It must also pass:

- one provider-free local headless scenario;
- exit statuses `0`, `1`, and `64`;
- all warm startup limits;
- first paint before runtime-ready state;
- input during startup;
- one queued submission that runs exactly once;
- startup failure display and clean exit;
- installation under a path with spaces;
- installation under a non-ASCII path;
- operation when the extracted package is not writable;
- `priv` data and native-library load checks;
- metadata, notice, inventory, and checksum validation;
- detection of changed or missing archive files;
- no live provider call and no credential requirement for help or version.

The harness must write machine-readable evidence. A failure must name the exact
gate and must make the candidate unusable for publication.

## Manual TUI acceptance

Run the final extracted archive in a modern macOS terminal. Record the terminal,
OS, target, artifact checksum, steps, result, and known limits.

The manual check must cover:

- first paint and runtime-ready state;
- input and one submission during startup;
- startup failure text and clean exit;
- raw input startup and cleanup;
- cursor and alternate-screen restoration;
- terminal resize;
- arrow keys, control keys, and bracketed paste;
- Unicode width and non-ASCII input;
- Braille display and fallback;
- ANSI 16-color, 256-color, and true-color modes;
- abnormal process termination.

Pseudo-terminal automation does not replace this manual check.

## Future distribution

### GitHub releases

GitHub will provide immutable artifact URLs. A future publication task will
upload the exact accepted archive, checksum, metadata, notices, SBOM,
provenance, and release notes. Signing and notarization can be added before a
stable public release.

### Homebrew

Homebrew work starts only after the local release flow is complete and a GitHub
artifact has an immutable URL. The future formula will install `bin/jido` from
the target archive and verify the exact SHA-256 value. It will not depend on
Homebrew Erlang or Elixir. It will not define a service.

Do not create or update the formula or tap during the current work.

### Other targets and channels

Add each later target with its own native build and the same acceptance
contract. Windows signing, Scoop, Winget, Linux ARM64, and `homebrew/core` are
separate later work. Hex publication stays deferred while Jido uses an immutable
Git dependency for Jidoka.

## Repository work required

Complete these items for the local end-to-end release:

1. Keep the immutable GitHub Jidoka dependency and clean-checkout build.
2. Make the Mix application version the only product version source.
3. Define the stable archive, package layout, and metadata contract.
4. Resolve the `llm_db` release application conflict in source.
5. Add a supported release entry module and relative platform launcher.
6. Add the Mix release and macOS ARM64 artifact builder.
7. Add the dependency license inventory and notices.
8. Add metadata, SBOM, provenance, and checksum generation.
9. Add the final-archive acceptance and startup harness.
10. Add one local command that runs the full flow and writes a complete `dist/`
    candidate.
11. Complete and record manual TUI acceptance on the final archive.

## Delivery phases

### Phase 1: release correctness

- use one product version;
- define the artifact contract;
- resolve the `llm_db` conflict;
- confirm the source-built Mix release and supported entry path.

### Phase 2: local artifact components

- implement the macOS ARM64 builder;
- generate notices, metadata, SBOM, provenance, and checksums;
- implement final-archive acceptance.

### Phase 3: local end-to-end release

- add one release command;
- run all source, package, and startup gates;
- produce one clean Brew-ready archive and evidence set;
- complete manual TUI acceptance.

### Phase 4: later publication

- sign and notarize when required;
- upload the accepted artifact to GitHub;
- use the immutable URL and checksum in a Homebrew formula;
- add other native targets and distribution channels separately.
