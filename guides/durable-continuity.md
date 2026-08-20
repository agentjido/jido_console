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
safe resource status, and the newest 200 product events. Use the bounded
history command to read older events.

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

The store has no migration or compatibility layer. This unreleased format can
change by replacing the development database.
