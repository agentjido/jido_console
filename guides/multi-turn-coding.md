# Multi-Turn Coding Development

This feature is in active development. It is not a stable release interface.

## Start A Local Thread

Build the executable and select one project root:

```sh
MIX_ENV=prod mix escript.build
./jido --coding-profile coding.local --project-root "$PWD"
```

The local profile is for macOS development. It uses `sandbox-exec`, has no
network access, and can run only registered Git and Mix helpers. It does not
provide a general shell.

Each thread has one temporary OTP owner. Jidoka owns request execution and the
durable conversation. Console owns one FIFO prompt queue and the product
history. Different thread IDs can run at the same time.

The owner prepares coding and extension resources only before the first prompt
starts. Each thread gets a private resource set. Opening, attaching, and
reading history do not require coding setup.

## Send And Queue Prompts

Press `Enter` to send a prompt. While one request runs, enter another prompt
and press `Enter` to add it to the FIFO queue. One request runs at a time in a
thread. Up to 32 prompts can wait.

Press `Ctrl-C` to cancel the active request. The next queued prompt starts only
after the cancellation outcome is durable. Exit an idle TUI with `Esc` or
`Ctrl-C`.

If an operation requires review, press `A` to approve or `D` to deny it. A
review pauses the active item and the queue. The continuation uses a new
private run reference, but it keeps the same public request ID.

## Use Coding Operations

Use a complete operation name and one JSON object for its arguments.

| Operation | Purpose | Smallest arguments |
| --- | --- | --- |
| `coding.read` | Read one relative text file | `{"path":"lib/file.ex"}` |
| `coding.search` | Search paths or text | `{"mode":"text","path":".","pattern":"term"}` |
| `coding.edit` | Replace exact text | `{"path":"lib/file.ex","old_text":"old","new_text":"new"}` |
| `coding.write` | Create or replace a file | `{"path":"lib/file.ex","content":"..."}` |
| `coding.git_status` | Read Git status | `{}` |
| `coding.git_diff` | Read the current diff | `{}` |
| `coding.verify` | Run one registered check | `{"helper_id":"mix-test"}` |

Paths are relative to the selected project root. The host validates all
arguments before it runs an operation.

An `@path` mention attaches an exact file to the prompt. Quote a path that has
spaces, such as `@"guides/my file.md"`. One prompt can attach at most 20 files
and 2 MiB in total. Use `\@` for a literal at sign.

## Understand Thread Status

| Status | Meaning |
| --- | --- |
| `idle` | The thread can start a prompt. |
| `starting` | Resources or the Jidoka bridge are starting. |
| `running` | Jidoka owns one active request. New prompts can enter the queue. |
| `review` | The active request waits for approval or denial. |
| `finishing` | Jidoka is terminal and the Console outcome must still commit. |
| `reconciling` | A replacement owner waits for a live lease or repairs durable state. |
| `unavailable` | A required durable operation failed. The queue does not advance. |

The TUI attaches to a complete revisioned View. It does not consume raw Jidoka
events. Live partial output exists only in the current owner. The newest 200
product events are in the View; older events remain available through bounded
history reads.

## Recover From Tool Errors

The local profile returns bounded coding errors as retryable observations. For
an edit conflict:

1. Read the file again.
2. Use its current text or SHA-256 value.
3. Submit a new guarded edit.
4. Run `coding.verify`.
5. Read Git status and diff.

An owner restart never resumes an old prompt. A live lease first reports
`reconciling`. After the lease ends, Console records interruption and accepts a
new prompt.

## Validate The Project

Run the normal checks from the repository root:

```sh
mix test
mix test --cover
mix precommit
MIX_ENV=prod mix escript.build
mix jido.check
```
