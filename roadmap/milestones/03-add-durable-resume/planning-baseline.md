# Milestone 3 Planning Baseline

This file freezes the design inputs for the proposed Milestone 3 epic
specifications. It is not product code, and it does not start Milestone 3
implementation. The Beadwork records are loaded early for work tracking only.

Milestone 3 implementation starts only after M2-E37 approves one exact
Milestone 2 source, Jidoka revision, roadmap version, and production candidate
as the v0.3 baseline.

## Milestone 2 Closeout and Beadwork Review

The local Beadwork review on 2026-08-16 found nine open Milestone 2 epics and
one open Milestone 3 planning record. No item was deferred or in progress.
Only M2-E09 was ready. The complete closeout chain was:

```text
M2-E09 -> M2-E17 -> M2-E18 -> M2-E26 -> M2-E27
       -> M2-E31 -> M2-E32 -> M2-E36 -> M2-E37
       -> jido_console-x5b
```

The closed M2-E11, M2-E28 through M2-E30, and M2-E33 through M2-E35 records
are historical evidence. They do not replace the final-source checks in
M2-E31, M2-E36, and M2-E37.

The `jido_console-m3` Beadwork parent and its 37 epic children were loaded on
2026-08-16 by explicit user direction. M3-E01 has M2-E37 as its only direct
cross-milestone blocker. The existing `jido_console-x5b` planning record also
has M2-E37 as its only direct blocker. It stays open so that it can compare the
preloaded records with the exact approved M2-E37 baseline, correct any drift,
verify the dependency graph, and only then close. Loading records does not
start Milestone 3 implementation.

## Storage Decision

Use SQLite as the default indexed store. The roadmap planning comparison chose
SQLite because the store needs ordered local transactions, conditional writes,
indexed replay, migrations, online backup, and integrity checks. Use one
declared Elixir SQLite adapter. Do not call a host `sqlite3` executable and do
not require a database service.

All Milestone 3 session-store files must stay below `JIDO_HOME/state/`. Other
product-created logs and artifacts remain in their existing owned directories
below `JIDO_HOME`. The default session-store layout is:

```text
JIDO_HOME/
  state/
    sessions/
      v1/
        console.sqlite3
        console.sqlite3-wal
        console.sqlite3-shm
        lock
        backups/
        archives/
        quarantine/
        manifests/
        tmp/
          sqlite/
          app/
```

Use one database file for the supported v0.3 local store. Keep Console and
Jidoka truth in separate table families and public contracts inside that file:

- Console tables store versioned JSON-compatible records.
- Jidoka tables store one bounded, versioned, checksum-protected Jidoka session
  value through the public `Jidoka.Session.Store` and
  `Jidoka.Session.Transitions` contracts.
- Console tables store only stable Jidoka identities, revisions, snapshot
  identities, and digests. They do not copy the Jidoka journal or checkpoint.

Use SQLite because Milestone 3 needs ordered transactions, unique idempotency
keys, conditional generation updates, indexed event ranges, schema migrations,
consistent backups, and integrity checks. DuckDB is not the default because
the work is transactional session state, not analytical query work. DETS
remains a Jidoka compatibility fixture, but it is not the default because its
mailbox, record growth, migration, indexed replay, and repair contracts do not
meet this milestone.

M3-E02 is skipped as a separate qualification gate. M3-E06 selects the direct
adapter and proves the minimum package, path, pragma, commit, reopen, crash,
and integrity behavior with the production store. Later operational epics
prove their own maintenance behavior.

## Frozen Storage Evaluation Matrix

This planning comparison uses the local repository requirements and the local
Jidoka and Jido Console source. It selects the engine class. It is not adapter
or performance proof. M3-E06 verifies the adapter behavior required by the
production store. M3-E17 and M3-E34 own backup and full crash evidence.

| Criterion | SQLite | DETS | DuckDB | Versioned plain files |
| --- | --- | --- | --- | --- |
| Local file below `JIDO_HOME`; no service | Meets the design | Meets the design | Meets the design | Meets the design |
| Ordered multi-record commit and conditional update | Native transactions, constraints, and one writer | Individual table operations need custom cross-record coordination | Transactions exist, but the engine is designed for analytical work | Needs a new transaction log and recovery protocol |
| Unique idempotency keys and indexed event ranges | Native unique and ordered indexes | Key lookup exists; ordered multi-index replay is custom | Query support exists; session-write qualification is not present | Needs new indexes, compaction, and corruption handling |
| One commit across separate Console and Jidoka table families | One database transaction | No shared transaction across the required record families | Technically possible, but it adds an unqualified analytical native dependency | Needs a new journal and commit protocol |
| Schema versions, migrations, and future-version rejection | Schema and migration ledger fit directly | Needs value rewrites and custom migration ownership | Schema work is possible but does not remove the package and writer gaps | Every migration and rollback rule is new code |
| Consistent backup and verified restore | SQLite `VACUUM INTO` supplies a transactional snapshot through SQL; integrity checks verify it | Close, sync, and copy do not give the required shared snapshot | Export and copy paths need separate qualification | Needs a new snapshot, manifest, and restore protocol |
| Integrity check, staged repair, and derived rebuild | Native integrity checks plus product digests | Limited engine checks; product repair remains custom | Engine checks exist, but the full local lifecycle is unqualified | All checks and repair tools are new code |
| Hard database, temporary-data, and growth limits | Page, WAL, reader, and temporary rules can be measured and enforced | No complete indexed replay, retention, archive, or compaction contract | File and temporary growth controls are not qualified for this package | Every limit and high-water calculation is new code |
| Bounded BEAM writer and reader integration | One supervised writer and bounded readers match the design | A wrapper is possible, but the current durable fixture has no complete bound | Native analytical execution adds a larger boundary to supervise | A wrapper is possible after a complete storage engine is built |
| Sync-before-reply and crash recovery | `FULL` synchronous transactions support the acknowledgement rule after production-store proof | Sync exists, but multi-record crash outcome needs a new protocol | Needs native package and crash qualification | Needs a new fsync, rename, journal, and replay proof |
| Latency and deadline qualification | M3-E06 proves the live path; each maintenance epic proves its own operation | Custom multi-record coordination has no qualifying result | Session-write latency is not qualified | New journal, fsync, and index work has no qualifying result |
| Packaged runtime and maintenance cost | M3-E06 declares and proves one direct adapter | Built into OTP, but functional gaps remain | Adds an unselected native analytical dependency | No dependency, but the project must build and maintain a database engine |
| Decision | **Selected engine class; adapter proof required** | Compatibility fixture only | Comparison fixture only | Manifest and small-file fixture only |

SQLite is the only option in this comparison that supplies the required
transaction, index, backup, and integrity primitives without making Jido
Console build a database engine or adopt an analytical engine. M3-E06 returns a
roadmap defect if its direct adapter cannot satisfy the live store contract.

## File and Security Rules

- The store root and each directory use mode `0700`.
- Each database, sidecar, lock, manifest, backup, archive, quarantine, and
  temporary file uses mode `0600`.
- Resolve every path through `Jido.Console.Home`.
- Use `lstat` checks on the state root and each owned entry. Reject symbolic
  links, non-regular store files, unsafe modes, unknown sidecars, and paths
  outside the state root.
- Put SQLite WAL, SHM, staging, backup, archive, repair, and temporary files
  under the versioned state root. Do not use `/tmp`, a workspace, `cache/`, or
  `run/` for durable work.
- Do not create an empty database when a known store is corrupt, incompatible,
  or unavailable.
- One home lock prevents two application instances from writing the same Jido
  home.
- File permissions protect against other normal operating-system users. They
  do not protect data from the current user or a privileged user.

Credential values are not Milestone 3 state. Jido-owned durable records store
only versioned, secret-free profile and reference identities. All Jido-owned
profile bytes stay in the database below `JIDO_HOME/state/`. A profile can
refer to a declared host environment variable, one user-owned private dotenv
file, or one existing read-only operating-system keychain item. These sources
are external runtime inputs. Jido does not create, change, copy, back up,
restore, archive, export, or delete their secret values.

Credential materialization occurs only for an explicit continuation and only
at the final provider or tool boundary. Attach, restore, transcript replay,
status, and audit do not resolve a secret. A missing profile, changed reference
identity, unavailable source, or denied source returns a typed stop. A rotated
value at the same immutable reference is allowed. Jido never stores a value
digest, prefix, suffix, or length.

## Sensitive-Value Admission Rule

Every durable entry path validates data before it creates a receipt, event,
Jidoka value, log, trace, artifact, or file. This rule applies to prompts,
command arguments, effect arguments and results, metadata, errors, and opaque
Jidoka values. Entry validation is structural. It does not resolve an external
credential source or compare input with its secret value.

- Product data accepts a credential profile or reference identity. It does not
  accept a credential-value field.
- Reject credential-value field names, inline authorization data, URI user
  data, query credentials, interpolation, shell credential arguments, and
  supported credential-bearing structures before the write.
- Return `sensitive_value_rejected` with redacted, bounded details. Do not
  create a durable receipt or an advisory wake-up.
- At the final provider or tool boundary, compare arguments and results with
  the credential value that is already materialized for that one call. If an
  external effect returns that value or fails the structural rule, keep only a
  process-local redacted result, return `sensitive_result_blocked`, and stop
  exact continuation. Do not report the effect as durably complete.
- The SQLite Jidoka adapter applies the same check before it encodes or writes
  a Jidoka value. A post-write scan is evidence only. It is not the control.
- Logs, errors, diagnostics, protocol output, backups, archives, quarantine,
  and candidate evidence contain stable identities and redacted status only.

This rule does not claim that the product can identify an arbitrary unknown
secret that a user pastes into ordinary prompt text. Such a claim would require
early secret resolution or a complete secret oracle. The v0.3 guarantee is
that credential-specific product fields accept references only, declared
credential sources resolve only at the final call boundary, and declared
credential canaries do not enter Jido-owned durable or output data.

## Initial Supported Limits

These limits are correctness bounds for v0.3. Configuration can lower an
operational limit. Raising a hard support limit needs a later roadmap and
quality decision.

| Limit | v0.3 value |
| --- | ---: |
| SQLite page size | 4,096 bytes |
| Active SQLite database | 262,144 pages, 1 GiB |
| Normal database admission ceiling | 221,184 allocated pages, 864 MiB |
| Reserved database control capacity | 40,960 pages, 160 MiB |
| Complete `state/sessions/v1` tree | 4 GiB |
| Normal state-tree admission ceiling | 3.5 GiB |
| Maintenance reserve inside the tree budget | 512 MiB |
| Active database sub-budget | 1,024 MiB |
| WAL sub-budget | 384 MiB |
| SHM, lock, manifest, tombstone, and control-file sub-budget | 16 MiB |
| Verified backup sub-budget | 1,024 MiB |
| Verified archive sub-budget | 512 MiB |
| Shared staging, quarantine, repair, and application-temporary sub-budget | 1,024 MiB |
| Unallocated structural safety | 112 MiB |
| Active durable sessions | 128 |
| One session Console records | 64 MiB |
| One session Jidoka value | 128 MiB |
| Canonical events in one supported session | 10,000 |
| One encoded Console record | 256 KiB |
| One semantic snapshot | 1 MiB |
| One startup-recovery suffix | 1,000 events or 8 MiB |
| Snapshot interval | 500 events or 8 MiB of suffix data |
| Retained verified snapshots | 3, plus referenced snapshots |
| Admitted writer operations | 128 total: 112 normal, 16 control |
| Small admitted writer payload | 16 MiB aggregate |
| One small writer request | 2 MiB |
| One large Jidoka request | 136 MiB including envelope overhead |
| Large writer lanes | 1 normal and 1 control |
| Total admitted logical payload | 288 MiB |
| Transactions in flight | 1 |
| SQLite WAL checkpoint target | 32 MiB |
| SQLite WAL normal-write stop | 64 MiB |
| SQLite WAL hard file limit | 384 MiB |
| SQLite reader connections | 16 total, 4 reserved for recovery and administration |
| SQLite read-transaction age | 1 second |
| SQLite busy timeout | 250 ms |
| SQLite writer page cache | 32 MiB |
| SQLite reader page cache | 8 MiB per connection |
| SQLite library heap hard limit | 512 MiB across store connections |
| Application temporary files | 64 MiB aggregate, 16 MiB each |
| Automatic pre-migration backups | 3 files and 1 GiB aggregate |
| Archive sets | 128 sets, 256 MiB each, 512 MiB aggregate |
| Concurrent recovery coordinators | 4 |
| Queued recovery sessions | 124, for 128 total active or queued |
| One recovery diagnostic result | 32 entries, 2 KiB each, 64 KiB total |
| Normal recovery wall-clock guard | 30 seconds per session |
| Migration wall-clock guard | 120 seconds per store |
| One history page | 128 records and 1 MiB encoded |
| One history-page token | 4 KiB encoded |
| Steering and follow-up queues | 128 items each and 8 MiB combined per session |
| Unresolved interactions and permissions | 64 of each per session |
| Credential profiles | 64 profiles, 16 versions per profile, 8 references per version, 16 KiB metadata per version |
| One session-catalog page | 64 entries and 256 KiB encoded |
| One removal dependency report | 512 entries and 1 MiB encoded |
| One external maintenance manifest | 64 KiB encoded |
| Confirmed-removal control allowance | 1 MiB database pages, 256 MiB WAL, 8 MiB control files |

The seven state-tree sub-budgets sum to exactly 4,096 MiB. Count each file by
the larger of logical size and allocated blocks. Sparse files cannot bypass a
limit. Admission reserves the worst-case high-water bytes for the source and
staged destination before work starts, then reconciles the reservation to the
measured final allocation.

Capacity is checked before durable acknowledgement. Normal work must leave
160 MiB of database page capacity and 512 MiB of state-tree capacity. Only
cancellation, safe completion, checkpoint finalization, recovery, bounded
audit-export metadata, confirmed session removal, confirmed whole-backup or
whole-quarantine retirement, and shutdown can use those reserves. One confirmed
removal or retirement can add at most 1 MiB of database pages, 256 MiB of WAL,
and 8 MiB of control files. It checkpoints below the 64 MiB WAL stop before it
starts and it does not start if its worst-case allocation can exceed the
384 MiB WAL or 4 GiB tree limits. At a hard limit, new normal durable work
returns a typed capacity result. The product never deletes authoritative active
state to make room.

Backups and archives count against their sub-budgets and the complete tree.
Three automatic backups are a count limit, not space for three full-size
databases. Surplus verified automatic backups can rotate before a new backup.
If one verified backup cannot fit, migration does not start. Staging,
quarantine, repair, and application temporary data share one 1 GiB pool. Only
one maintenance operation and one non-active store image can exist at a time.
An existing source stays charged to its current active-database, backup, or
archive sub-budget. Only the staged non-active image is charged to the shared
pool. At a replacement boundary, an external operation manifest changes the
roles so that exactly one image uses the active-database budget and exactly one
old or staged image uses the shared pool. Same-file-system renames do not create
a second copy. The total-tree high-water check still counts every image.
If a limit is reached, the user must explicitly remove retained data or wait
for a later approved export policy. The package does not grow its durable tree
without a bound.

## SQLite Durability Contract

Open the database with these verified settings:

- `journal_mode = WAL`
- `synchronous = FULL`
- `foreign_keys = ON`
- `busy_timeout = 250`
- `page_size = 4096` for a new store
- `auto_vacuum = INCREMENTAL` for a new store
- `max_page_count = 262144`
- `temp_store = MEMORY` for bounded normal queries
- `cache_size = -32768` on the writer and `cache_size = -8192` on each reader
- `hard_heap_limit = 536870912`, or the selected adapter's proved equivalent,
  across all store connections
- A configured SQLite temporary directory below
  `JIDO_HOME/state/sessions/v1/tmp/sqlite` before the first connection, for any
  selected adapter operation that can create a file-backed temporary file
- A 32 MiB WAL checkpoint target, 64 MiB normal-write stop, and 384 MiB hard
  allocation limit

Use `BEGIN IMMEDIATE` for write transactions. A durable acknowledgement means
that SQLite reported a successful commit under the verified `FULL` synchronous
contract and the writer returned the matching committed receipt. The public
deadline is 1 second. At that deadline, return `timeout_unknown` with the
operation identity. Do not claim that the transaction rolled back.

Start a passive checkpoint at 32 MiB. A busy checkpoint does not revoke an
earlier commit. Deny new non-control readers, retry after the oldest reader
closes, and stop normal writes at 64 MiB or after one 250 ms busy interval.
Reserved writes can continue only if their worst-case WAL allocation stays
below 384 MiB. Interrupt an owned reader at its 1-second age limit and attempt
restart then truncate checkpoint. If the checkpoint stays busy, return
`checkpoint_blocked`, stop every write that can add pages, preserve the WAL,
and restart through storage recovery. Never delete or rename a live WAL.

Normal SQL queries use indexed order and bounded result windows. Sort,
migration, backup, integrity, archive, repair, and recovery probes must show
that SQLite and application temporary files remain below `JIDO_HOME`. There is
no fallback to `/tmp`, `TMPDIR`, a workspace, `cache/`, or `run/`. This
durability contract does not claim protection from faulty hardware or a host
that does not honor durable flush operations.

## Durable Record Inventory

### Console authoritative records

| Record | Required identity and purpose |
| --- | --- |
| Store manifest | Format, schema, migration checksums, product instance, limits |
| Session manifest | Session, lifecycle, generation, continuity mode, current heads |
| Generation claim | Session, generation, owner instance, prior generation |
| Canonical Console event | Event ID, sequence, class, origin, trust, sensitivity, digest link |
| Input receipt | Idempotency key, payload digest, input identity, admission state |
| Command receipt | Idempotency key, command identity, effective arguments, result identity |
| Queue mutation | Queue type, item identity, order, add or remove result |
| Interaction and permission | Request, scope, principal, expiry, decision, consumption |
| Turn manifest | Provider, model, settings, prompt, tool, skill, workspace, credential references |
| Effect reservation | Result identity, effective arguments, safety class, replay rule, approval |
| Effect resolution | Completed, failed, uncertain, reconciled, or abandoned result |
| Watermark | Console and Jidoka identities at one verified boundary |
| Fork reservation and lineage | Idempotent child identity, parent boundary, authority reset |
| Administrative decision | Migration, repair, backup, restore, archive, abandon, removal |
| Audit chain | Prior digest, current digest, schema, session, generation, sequence |

### Jidoka authoritative records

The Jidoka store value remains the only execution truth for:

- Jidoka session data and revision
- Conversation and request state
- Jidoka snapshots and checkpoints
- Effect intents and results
- Pending runtime review state
- Worker lease and recovery state
- Execution-environment binding and checkpoint
- Jidoka fork lineage

The SQLite Jidoka adapter stores this value in its own bounded table. Console
does not project the Jidoka journal into a second runtime history.

### Derived and rebuildable records

- Semantic snapshots
- Transcript and outcome projections
- Queue and permission indexes
- Session catalog and search indexes
- Compact model context
- Client history-page indexes
- Audit views and reports
- Archive indexes

Each derived record names its source sequence, source digest, and schema. A
mismatch causes a bounded rebuild.

### Process-local records

- Client and attachment identities
- Client receiver processes, monitors, and delivery queues
- Delivery acknowledgement and recovery tokens
- Worker and task processes, monitors, ports, and timers
- Writer calls and admission reservations
- Raw runtime request handles and provider clients
- Extension hosts and runtime capability functions

These values never recover as authority. A restart creates new attachments,
workers, timers, owner instances, and delivery baselines.

### Forbidden durable records

- Credential values, API keys, passwords, tokens, cookies, or secret
  environment values
- PIDs, references, ports, functions, monitors, tasks, or open clients
- Renderer draft, cursor, viewport, terminal, DOM, or timing state
- Raw provider clients or unbounded provider payloads
- Raw Jidoka history in Console records
- Authority inferred from a transport, renderer, origin string, or capability
  description

## Acknowledgement Rules

| Item | Durable acknowledgement rule |
| --- | --- |
| Input | Receipt, payload digest, admission event, and sequence commit before wake-up |
| Mutating command | Receipt, effective arguments, result identity, and semantic event commit before effects |
| Console event | Valid canonical JSON, unique event and sequence, chain digest, and store commit |
| Jidoka checkpoint | Public Jidoka store transition completes and returns the committed revision and snapshot identity |
| Effect start | Result identity, arguments, safety class, replay rule, and required approval are durable first |
| Effect result | Jidoka result is durable before Console records completion |
| Watermark | Both sides match by identity and digest, then the verified link commits last |
| Client output | Process-local only; confirms application by one live attachment |

Structural credential-bearing validation occurs before every item in this
table. A rejected structure has no durable acknowledgement candidate. External
credential-value containment occurs only at the final provider or tool call.

The durable uniqueness key for input and commands is:

```text
session_id + operation_kind + principal_id + idempotency_key
```

The same key and payload digest return the existing receipt. The same key with
a different digest returns `idempotency_conflict`. A timeout after submission
returns an unknown-commit result and the caller queries or retries with the
same key. No uncertain timeout creates a second operation.

## Process Ownership and Startup Order

```text
Application supervisor
  -> Jido home validation and home lock
  -> storage supervisor
       -> supervised maintenance coordinator
            -> external maintenance-manifest recovery before SQLite opens
       -> bounded admission counters
       -> one SQLite writer
       -> one store-wide migration and integrity gate
  -> recovery supervisor
       -> session catalog
       -> bounded per-session recovery coordinators
  -> session registry and dynamic session supervisor
       -> one generation-fenced Session.Server for each ready session
       -> runtime workers
       -> client delivery
```

Use rest-for-one ordering across storage, recovery, and session supervision. A
writer failure stops normal session mutation and restarts recovery from the
durable boundary. The maintenance coordinator starts before any SQLite
connection opens. It is the only owner while the writer is stopped and it owns
startup recovery of the external manifest. It records each store-wide operation in a canonical JSON
manifest below `manifests/`. It writes a private temporary file, syncs it,
renames it on the same file system, and syncs the parent directory. The
coordinator reconciles this manifest before it permits SQLite to open. Storage work, store migration,
reconciliation, and index rebuild do not run in `Session.Server`.

Run at most four recovery coordinators. Queue at most 124 more sessions, so
active plus queued recovery never exceeds the 128-session support limit.
Reserve four of the 16 reader connections for recovery and administration.
Each coordinator can load one 1 MiB snapshot, one internal suffix of at most
1,000 events or 8 MiB, and one Jidoka value of at most 128 MiB. Other scans use
bounded pages. A coordinator never loads the 64 MiB Console history as one
value.

A recovery result has at most 32 diagnostic entries, 2 KiB per entry, and
64 KiB total. Each entry contains a code, phase, session identity, safe record
identity, and redacted details. Normal recovery stops at 30 seconds and returns
a typed result. Migration stops at 120 seconds. Candidate qualification still
must meet its tighter 10-second p95 and 15-second exact-recovery maximum.

The store startup lifecycle is:

```text
validating_home
  -> recovering_maintenance
  -> migrating_store
  -> verifying_store
  -> store_ready
```

M3-E18 runs migration once for the complete store before the session catalog
starts. A per-session coordinator only verifies that it sees the current schema.
It cannot start or repeat a store migration.

The per-session classification lifecycle is:

```text
loading
  -> claiming_generation
  -> verifying_history
  -> reconciling
  -> rebuilding
  -> exact_candidate | transcript_candidate | repair_required | unavailable
```

The continuity-mode epics consume a candidate and produce a ready owner:

```text
exact_candidate -> ready_exact
transcript_candidate -> ready_transcript_only
```

A classified candidate cannot report ready, accept normal attachment, or wake
execution. M3-E22 or M3-E23 must activate the selected mode first.

## Session Generation Fence

Each owner incarnation atomically claims a larger durable generation and a new
owner-instance identity. Every mutating storage operation checks:

```text
session_id + generation + owner_instance_id + operation_id
```

Fence worker results, runtime events, timers, cancellations, permission
expiry, storage commands, storage replies, checkpoint callbacks, watermark
commits, recovery completion, client operations, client acknowledgements, and
fork completion. A stale operation fails before storage mutation. The Console
generation complements the Jidoka lease; it does not replace it.

## Console-to-Jidoka Watermark

The verified watermark contains:

```text
Console session ID
Console generation
Console sequence and event ID
Console chain digest
Jidoka session ID
Jidoka session revision
Jidoka snapshot ID
Jidoka value digest
Jidoka request and lease identity
Console protocol and durable schema versions
```

Use these states:

```text
reserved -> jidoka_committed -> console_committed -> verified
                                            \-> repair_required | abandoned
```

The physical commit order is:

1. Commit the Console receipt and admission record.
2. Wake the Jidoka execution path.
3. Let Jidoka commit its intent, checkpoint, or result through the SQLite store adapter.
4. Commit the deterministic canonical Console projection.
5. Read and compare both committed identities and digests.
6. Commit the verified watermark last.

Recovery handles these cases:

| Durable state | Result |
| --- | --- |
| Neither side committed | Retry only under the recorded operation rule |
| Accepted Console input, no started Jidoka work | Mark it in the exact candidate; M3-E22 wakes it once after `ready_exact` because the durable receipt is the existing explicit request |
| Jidoka checkpoint, no Console projection | Recreate only the deterministic projection and verify |
| Console execution projection, no Jidoka checkpoint | Stop exact resume; repair, abandon, or use explicit transcript-only mode |
| Both sides present with different identity or digest | Stop with `repair_required` |
| Both sides present and equal | Commit or reuse one verified watermark |

Canonical history is immutable. Reconciliation appends a decision. It does not
rewrite the original record.

## Operation Matrix

| Operation | Calls a model or tool during the operation | Verified watermark required | Authority rule |
| --- | ---: | ---: | --- |
| Pure replay | No | No | Data projection only |
| Recovery load | No | No | No execution authority |
| Exact state restore | No | Yes | New generation and valid Jidoka lease |
| Exact continuation | Yes | Yes | Explicit request after `ready_exact` |
| Transcript-only restore | No | No | Read-only and visibly degraded |
| Retry | Yes | No | New request, result, receipt, and safety decision |
| Exact fork | No during fork | Yes | New session and no live authority transfer |
| Transcript-only fork | No during fork | No | New read-only Console session |
| Physical store repair | No | Depends on fault | Verified staged replacement and audit record |
| Session reconciliation | No | Depends on case | Explicit supported decision only |
| Abandon | No | No | Blocks later automatic execution |
| Client attach | No | Depends on selected mode | New attachment in the current generation |

Exact resume never changes silently to transcript-only resume. An incomplete
unsafe effect is `uncertain` and is never repeated automatically.

## Snapshot, Replay, and History Rules

- Canonical event and receipt history is immutable until verified archive or
  explicit confirmed removal.
- A semantic snapshot is derived. It does not contain the complete history.
- Build a snapshot every 500 events or 8 MiB of suffix data, and at a safe
  terminal, approval-wait, hibernation, fork, or archive boundary.
- Keep the latest three verified snapshots and every snapshot referenced by a
  watermark or fork.
- Recovery uses the latest valid snapshot at or before the watermark and a
  suffix of at most 1,000 events or 8 MiB.
- If bounded replay cannot reach the head, return `snapshot_rebuild_required`.
  Do not run an unbounded startup replay.
- Client attach returns one current-state snapshot of at most 1 MiB. Older
  transcript data uses ordered, identity-bound pages of at most 128 records
  and 1 MiB, including a page token of at most 4 KiB. A page stops before
  either limit and never splits a record. M2 client gap recovery keeps its
  1,000-event and 1 MiB suffix limit. Normal live output remains incremental.
- Prompt compaction is a supervised, bounded projection. It never removes the
  source history used for audit, replay, or fork.

## Migration, Backup, Repair, and Retention

- Use ordered migration modules with source version, target version, checksum,
  preconditions, transaction, and verification.
- Reject an unknown future schema before any write.
- Create and verify a pre-migration SQLite backup before the first migration.
- Use SQLite `VACUUM INTO` while the writer owns a backup barrier. Do not copy
  an open database with ordinary file-copy logic.
- Restore only after the incoming database, manifest, schema, chain heads,
  watermarks, and checksums verify.
- Preserve the prior live store until staged replacement verifies.
- Quarantine corruption under the state root. Never repair authoritative data
  automatically or replace it with an empty session.
- Automatic maintenance can remove only rebuildable data, safe WAL pages,
  expired staging data, and surplus verified automatic backups.
- A whole-store backup or quarantine image is one indivisible retained copy.
  Do not rewrite it to remove one session. An explicit report-bound whole-image
  retirement can remove it only as one unit. Session removal stays blocked
  while such an image contains the selected session.
- Archive a terminal or abandoned session to canonical Console JSONL, one
  checksum-protected opaque Jidoka value when execution evidence exists, and a
  manifest. Verify the complete archive, commit the archive decision, and only
  then remove active Console and Jidoka rows.
- An archive preserves audit and fork ancestry. It does not authorize exact
  resume or archive rehydration in v0.3.
- Preserve fork ancestry or a verified archived copy while a child depends on
  it.
- Abandon keeps audit history. Removal destroys retained data only after an
  explicit confirmation and dependency report. It runs only for a stopped
  terminal or abandoned session behind a session and writer maintenance barrier.
- Check the full source-plus-destination high-water size before backup,
  migration, restore, quarantine, repair, archive, or removal starts.
- Keep at most three verified automatic backup files and 1 GiB of automatic
  backups in total. Rotate only surplus verified automatic backups.
- Use same-filesystem rename for the verified replacement boundary. Do not
  make a second copy when a rename preserves the old image.
- Keep at most 128 archive sets, 256 MiB per set, and 512 MiB in total. Never
  delete an archive automatically.

## Crash-Injection Matrix

The proof epics must inject failure at least at these points:

| Fault point | Required result |
| --- | --- |
| Before writer admission | No write and no acknowledgement |
| Admitted before writer receives | Bounded queue; retry by operation ID |
| Transaction before commit | Full rollback |
| Commit before writer reply | Query or retry returns the same receipt |
| Writer reply before caller receives | Same receipt; no duplicate |
| Input commit before wake-up | Recovery wakes it once |
| Effect reservation before dispatch | Safe retry rule remains explicit |
| Unsafe dispatch before result | Mark uncertain; never repeat automatically |
| Jidoka checkpoint before Console projection | Deterministic projection or repair-required |
| Console projection before Jidoka checkpoint | No false exact-resume claim |
| Both sides before watermark | Verify and commit the link once |
| Generation claim before owner starts | New owner reuses or advances safely |
| Session owner, worker, or runtime controller death | Recovery uses durable truth and fences stale results |
| Writer death | No false acknowledgement; session mutation stops |
| Application exit or operating-system kill | All acknowledged state returns |
| WAL checkpoint | Committed transaction remains valid |
| Persistent reader during checkpoint | Reader is interrupted at its bound; WAL growth stops before the hard limit |
| Checkpoint stays busy | Writes that add pages stop; WAL remains intact for storage recovery |
| Migration, backup, restore, repair, archive, or removal staging | Old or new verified copy remains; no partial authority |
| SQLite sort, integrity, and recovery temporary work | No file appears outside the versioned state root |
| Disk full or permission failure | Typed storage failure before acknowledgement |
| Corruption or future schema | Typed unavailable or repair-required result; no empty store |
| Old worker, timer, storage reply, or client | Generation fence rejects it |

The final proof records deterministic seeds, acknowledged operation IDs,
durable digests, process exit points, file sizes, queue counts, and recovery
results.

## Qualification Profile

The v0.3 production candidate must measure these results on the recorded
macOS ARM64 reference system:

| Measure | Target |
| --- | ---: |
| Durable acknowledgement p95 | 250 ms |
| Durable acknowledgement maximum | 1 second |
| Exact recovery ready p95 | 10 seconds |
| Exact recovery ready maximum | 15 seconds |
| Post-ready client attach p95 | 1 second |
| Migration ready p95 | 30 seconds |
| Warm measurement runs | 20 |
| Operating-system kill repetitions for each critical durability window | 25 |

Time values are candidate qualification targets for the recorded system. They
are not general performance claims. Count, byte, identity, ordering, and
durability limits are product correctness rules.
