# Multi-Turn Coding Development

This guide describes the current local coding path. The feature is in active
development. It is not a supported release interface.

## Start The Local Profile

Build the developer executable, then give the TUI one explicit project root:

```sh
MIX_ENV=prod mix escript.build
./jido --coding-profile coding.local --project-root "$PWD"
```

The local profile is for macOS development. It uses `sandbox-exec`, has no
network access, and can run only the registered `git` and `mix` helpers. It
does not expose a general shell tool.

The TUI starts one Jidoka session. Each completed turn returns an updated
session, and the next prompt uses it. This keeps user messages, assistant
messages, and tool observations across turns. A failed or cancelled turn does
not replace the last completed session.

To run the provider-free Jidoka conversation example:

```sh
cd ../jidoka
mix run examples/getting_started/example.exs
```

## Use The Tool Protocol

Use the complete operation name and one JSON object for its arguments.

| Operation | Purpose | Smallest arguments |
| --- | --- | --- |
| `coding.read` | Read one relative text file | `{"path":"lib/file.ex"}` |
| `coding.search` | Search paths or text | `{"mode":"text","path":".","pattern":"term"}` |
| `coding.edit` | Replace exact text | `{"path":"lib/file.ex","old_text":"old","new_text":"new"}` |
| `coding.write` | Create or replace a file | `{"path":"lib/file.ex","content":"..."}` |
| `coding.git_status` | Read Git status | `{}` |
| `coding.git_diff` | Read the current diff | `{}` |
| `coding.verify` | Run one registered check | `{"helper_id":"mix-test"}` |

A model decision is `final`, `operation`, or `operations`. The local profile
runs one operation at a time. A turn can still make many tool calls: the model
returns one decision, waits for the observation, and then makes the next
decision. It must not invent an observation or shorten an operation name.

Paths are relative to the selected project root. Reads, searches, writes,
edits, Git inspection, and registered verification are separate capabilities.
The host validates arguments before it runs a capability.

If a host policy requires review, the TUI stops before the operation. Press
`A` to approve or `D` to deny. The resumed operation remains in the same turn
and session.

## Know The Limits

The current `coding.local` profile uses these bounds:

- 12 model steps and 180 seconds for one turn;
- one operation at a time;
- 4,000 output tokens for the selected model;
- 120 seconds and 256 KiB of output for `mix test`;
- 256 KiB for one file or one tool result;
- 2,000 searched files and 100 search results;
- no network access and no general shell;
- 100 retained TUI turns.

An `@path` mention attaches an exact file to the prompt. Quote a path that has
spaces, such as `@"guides/my file.md"`. One prompt can attach at most 20 files
and 2 MiB in total. Use `\@` for a literal at sign.

## Recover A Turn

The local profile returns a bounded coding error to the model as a retryable
observation. For an edit conflict, the normal recovery is:

1. Read the file again.
2. Use its current text or SHA-256 value.
3. Submit a new guarded edit.
4. Run `coding.verify`.
5. Read Git status and diff.

The model must stay inside the turn limits. A fatal error or exhausted limit
ends the turn. `Ctrl-C` requests bounded cancellation. After cancellation, send
a new prompt from the last completed session. Exit the idle TUI with `Esc` or
`Ctrl-C`.

## Read TUI State

| Status | Meaning |
| --- | --- |
| `starting runtime` | The first frame is visible; one prompt can be queued. |
| `idle` | The TUI can accept a prompt. |
| `resolving file mentions` | The TUI reads and bounds `@path` attachments. |
| `running` | The model or a tool is active. |
| `review required` | Press `A` or `D` for the pending operation. |
| `sending review decision` | The turn is resuming after the decision. |
| `cancelling` | The TUI is waiting for bounded cleanup. |
| `interrupted` | The runtime paused without an interactive review. |
| `error` | The turn or runtime failed; read the shown reason. |

Tool rows move through `planned`, `running`, `done`, `failed`, or `retried`.
The review panel shows bounded edit and Git-diff evidence after a turn.

## Keep Versioned Data Stable

Local release metadata uses `jido.release` schema version `1`. That version is
independent of the CLI package version and the Jidoka session schema version.

## Validate A Local Artifact

Run the complete source, archive, private-runtime, startup, and provider-free
acceptance path from the CLI repository:

```sh
mix jido.release
```

The normal command requires a clean checkout. During local development, use:

```sh
mix jido.release --allow-dirty
```

The dirty form makes an unsigned, non-publishable candidate. Inspect
`dist/release.json`, `dist/acceptance.json`, `dist/checksums.txt`, and
`dist/manual-tui.json`. Complete the manual TUI checklist against the exact
archive before you treat local validation as complete.

This work does not include an independent daemon, Brew integration, signing,
notarization, upload, or publication.
