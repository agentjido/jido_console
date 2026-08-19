# Local Session Storage

Jido Console stores local session data in one SQLite database:

```text
JIDO_HOME/state/console.sqlite3
```

The database uses `WAL` mode and `synchronous=FULL`. One process owns its
writable connection. A separate home lock prevents two Jido Console processes
from writing to the same home.

The database has two product tables:

- `events` contains ordered Console events.
- `operations` contains idempotent input and command admission state.

An input is acknowledged only after its operation row and event row commit in
one transaction. A repeated idempotency key with the same payload returns the
existing receipt. A repeated key with different data returns a conflict.

Session restart reads at most 10,000 events and rebuilds state with the normal
session reducer. Provider and tool work does not restart automatically. An
incomplete run becomes interrupted process state and requires a new request.

The current store has no migration or compatibility layer. An earlier
development database under `state/sessions/v1` is not read or changed.
