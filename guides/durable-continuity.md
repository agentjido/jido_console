# Local Thread Storage

Jido Console uses three clear data authorities:

- Jidoka session data is the durable execution authority.
- Console thread events are the durable product-history authority.
- The live thread owner produces the current complete client View.

The local SQLite database is at:

```text
JIDO_HOME/state/console.sqlite3
```

SQLite uses `WAL` mode and `synchronous=FULL`. One process owns the writable
connection. A home lock prevents two Console processes from writing to the
same home.

All storage access uses the `Jido.Console.Storage.Adapter` contract. SQLite is
the default adapter. A host can set another adapter in its application
configuration:

```elixir
config :jido_console, :storage_options,
  adapter: MyConsole.Storage,
  adapter_option: :value
```

The selected module must implement the `Jido.Console.Storage.Adapter`
behaviour.

## Stored Data

The runtime has two tables:

- `sessions` stores validated `Jidoka.Session.Data` values.
- `thread_events` stores ordered Console product events.

Thread events record prompt queue, start, removal, review, success, failure,
cancellation, and interruption. They do not duplicate Jidoka leases,
checkpoints, snapshots, or execution transitions.

A prompt is accepted only after `prompt_queued` commits. The client command ID
is also the queue-item ID. A retry with the same command ID and the same data
returns the existing item. Different data returns a conflict.

Each accepted item has this small durable lifecycle:

```text
queued -> started? -> one closing outcome
```

The store validates this lifecycle and the thread sequence in one transaction.

## Live Queue And View

One temporary OTP owner exists for each active thread. It runs one Jidoka
request and keeps one FIFO queue with at most 32 waiting prompts. The queue is
live process state. It is not a durable scheduler.

An attachment gets one complete, revisioned View. The View contains the
committed transcript, current partial output, active public IDs, review, queue,
safe binding and resource status, and the newest 200 product events. The safe
binding identifies the agent source by kind, label, and digest. It does not
contain the canonical source path. Use the bounded history command to read
older events.

## Durable Binding And Exact Resume

Before the first prompt, the owner stores a draft binding with an agent source,
model and origin, coding pack, execution policy, workspace identity, semantic
digests, and the trusted runtime-definition fingerprint. The first prompt lock
updates the session and inserts `prompt_queued` in one SQLite transaction. A
failure cannot leave only one side of that pair.

The locked binding is authoritative on attach and owner replacement. Incoming
explicit values are assertions only. Console rebuilds and compares the exact
source bytes, base and bound specifications, model, policy evidence, trusted
registration, runtime fingerprint, and workspace identity before it opens a
provider, adapter, tool, or extension. A mismatch enters the read-only
`resume_blocked` state. It does not silently use a current default.

In the TUI, `/new-session` creates a new thread ID and copies no transcript,
queue, lease, review, automation, result, or direct execution-policy consent.
An agent policy request must receive a new exact user choice. `/cancel` closes
the blocked read-only TUI.

## Owner Replacement

A replacement owner first checks Jidoka state and open Console events. It does
not resume old work.

- A live Jidoka lease keeps the owner in `reconciling` state. Work commands
  return `thread_reconciling`.
- A durable terminal Jidoka state wins. The owner adds the missing matching
  Console outcome once.
- After lease expiry, the owner claims recovery, commits an interruption
  through the public Jidoka store, and closes all accepted old items.
- Queued old items also become interrupted. They do not run after restart.

Active-request cancellation is supervised and durable. The remaining FIFO
cancellation gap is tracked in
[issue #28](https://github.com/agentjido/jido_console/issues/28). This release
does not add a native helper for that gap.

## Store Compatibility

The binding release raises the Console store reader version from 2 to 3. A
valid version 2 store gets an integrity-checked marker-only upgrade. Its session
and event tables are not rewritten. A previous reader refuses a version 3 store
before writes or resource callbacks, because that reader cannot preserve a
binding manifest. In-place downgrade is not supported.

A legacy session without a binding manifest can adopt the current binding only
when every conversation, request, snapshot, result, error, lease, environment,
metadata, lineage, and product-event field proves that the session was unused.
All other legacy sessions remain readable but enter `resume_blocked` without a
storage mutation.

For older incompatible development schemas, startup keeps the existing backup
behavior. It moves the database and SQLite sidecars into a private
`console.sqlite3.schema-VERSION-backup` directory before it creates a new
database. Startup stops when it cannot make that backup safely.
