# Durable Continuity Contract

This guide describes the frozen Jido Console v0.3 durability contract. The
canonical machine-readable contract is `jido.continuity` version 1. The
additive protocol values remain in `jido.session` version 1.

This contract does not open a database, recover a session, or give execution
authority. Later Milestone 3 work must implement and prove it without changing
its rules in an implementation pull request.

## File-Only Storage Boundary

SQLite is the selected local engine class. The default store declares one
direct Elixir adapter and proves its required behavior with the production
store. The product does not call a host `sqlite3` command and does not use a
database service.

All session-store files are below this root:

```text
JIDO_HOME/state/sessions/v1/
  console.sqlite3
  console.sqlite3-wal
  console.sqlite3-shm
  lock
  backups/
  archives/
  quarantine/
  manifests/
  tmp/sqlite/
  tmp/app/
```

Directories use mode `0700`. Files use mode `0600`. A symbolic link, an
unknown sidecar, an unsafe mode, or a path outside the root must fail closed.
The contract does not permit a fallback to a workspace, `cache/`, `run/`,
`/tmp`, or `TMPDIR`.

## Record Inventory

Each planned record has one owner, one class, and one durability value in the
versioned contract.

| Class | Owner rule | Records |
| --- | --- | --- |
| Authoritative Console | Console store or session | Store and session manifests, generation claims, canonical events, receipts, queues, interactions, permissions, turn manifests, effects, watermarks, forks, administrative decisions, audit chains, and credential-profile references |
| Authoritative Jidoka | Public Jidoka session store | Session value, conversation and request state, snapshots, checkpoints, effects, review state, leases, recovery state, environment binding, and fork lineage |
| Derived | Console projection | Semantic snapshots, transcript and outcome projections, indexes, compact model context, history pages, audit views, and archive indexes |
| Process local | The live process named by the record | Attachments, delivery queues and acknowledgements, workers, timers, writer calls, provider clients, extension hosts, and runtime functions |
| Sensitive | Final provider or tool boundary | A materialized credential value and its process-local redacted blocked result |
| Forbidden | No owner | Credential values, BEAM runtime values, renderer state, raw provider clients, unbounded provider data, copied Jidoka history, and descriptive authority |

Console records do not copy the Jidoka journal or checkpoint. A derived record
names its source sequence, source digest, and schema. A mismatch causes a
bounded rebuild. A process-local or sensitive value cannot recover as
authority.

## Acknowledgement Rules

Structural sensitive-value validation occurs before each rule in this table.

| Item | Exact operation that acknowledges it | Required committed data | Boundary before later work |
| --- | --- | --- | --- |
| Input | SQLite `FULL` commit and matching writer receipt | Input receipt, payload digest, admission event, sequence | Execution wake-up |
| Mutating command | SQLite `FULL` commit and matching writer receipt | Command receipt, effective arguments, result identity, semantic event | Effect dispatch |
| Console event | SQLite `FULL` commit and matching writer receipt | Canonical JSON, event identity, sequence, chain digest | Receipt return |
| Jidoka checkpoint | Public Jidoka store transition | Jidoka revision and snapshot identity | Checkpoint receipt return |
| Effect start | SQLite `FULL` commit and matching writer receipt | Result identity, arguments, safety class, replay rule, approval | External dispatch |
| Effect result | Public Jidoka store transition | Jidoka result and revision | Console completion |
| Watermark | Verified watermark commit | Matching Console and Jidoka identities and digests | Exact-resume claim |
| Client output | Live attachment applies the sequence | Attachment identity and applied sequence | Process-lifetime acknowledgement only |

A timeout after submission returns `timeout_unknown` with the same operation
identity. It does not report a rollback. A retry uses the same uniqueness key:

```text
session_id + operation_kind + principal_id + idempotency_key
```

The same key and payload digest returns the existing receipt. The same key and
a different digest returns `idempotency_conflict`.

## Generation and Watermark

Each owner incarnation atomically claims a larger durable generation and a new
owner-instance identity. Each mutating operation checks:

```text
session_id + generation + owner_instance_id + operation_id
```

This fence applies to workers, runtime events, timers, cancellations,
permission expiry, storage commands and replies, checkpoints, watermarks,
recovery results, client operations and acknowledgements, and fork completion.
A stale value fails before storage mutation. The Console fence complements the
Jidoka lease. It does not replace that lease.

One watermark contains the exact Console session, generation, sequence, event,
and chain digest. It also contains the exact Jidoka session, revision, snapshot,
value digest, request, and lease. It names the Console protocol and durable
schema versions.

```text
reserved -> jidoka_committed -> console_committed -> verified
                                            \-> repair_required | abandoned
```

Only `verified` can support exact resume. The verified link commits last.
Canonical history is immutable. Reconciliation appends a decision and does not
rewrite an earlier record.

## Recovery States

The store reaches readiness in this order:

```text
validating_home
  -> recovering_maintenance
  -> migrating_store
  -> verifying_store
  -> store_ready
```

One session is classified in this order:

```text
loading
  -> claiming_generation
  -> verifying_history
  -> reconciling
  -> rebuilding
  -> exact_candidate | transcript_candidate | repair_required | unavailable
```

A candidate has no execution authority. The exact-resume or transcript-only
resume operation must create `ready_exact` or `ready_transcript_only` before a
normal client can attach.

## Operation Matrix

| Operation | Can call a model or tool during the operation | Watermark | Authority rule |
| --- | ---: | --- | --- |
| Pure replay | No | Not required | Data projection only |
| Recovery load | No | Not required | No execution authority |
| Exact resume | No | Required and verified | New generation and valid Jidoka lease |
| Exact continuation | Yes | Required and verified | New explicit request after `ready_exact` |
| Transcript-only resume | No | Not required | Read-only and visibly degraded |
| Retry | Yes | Not required | New request, result, receipt, and safety decision |
| Exact fork | No | Required and verified | New session with no live authority transfer |
| Transcript-only fork | No | Not required | New read-only Console session |
| Repair | No | Depends on the fault | Verified replacement or explicit supported decision |
| Reconciliation | No | Depends on the case | Explicit supported decision only |
| Abandon | No | Not required | Blocks later automatic execution |
| Client attach | No | Depends on the selected mode | New attachment in the current generation |

Exact resume does not silently change to transcript-only resume. An incomplete
unsafe effect is `uncertain` and cannot repeat automatically.

## Hard Support Limits

The machine-readable contract contains every exact count, byte, time, page,
queue, reader, writer, replay, file, and diagnostic limit. These key limits
define the v0.3 support boundary:

| Area | Hard limit |
| --- | ---: |
| SQLite page size | 4,096 bytes |
| Active database | 262,144 pages, 1 GiB |
| Normal database admission | 221,184 pages, 864 MiB |
| Reserved database control capacity | 40,960 pages, 160 MiB |
| Complete state tree | 4 GiB |
| Normal state-tree admission | 3.5 GiB |
| Maintenance reserve | 512 MiB |
| WAL checkpoint, normal stop, hard limit | 32 MiB, 64 MiB, 384 MiB |
| Active durable sessions | 128 |
| One session Console records | 64 MiB |
| One session Jidoka value | 128 MiB |
| Canonical events in one session | 10,000 |
| One Console record | 256 KiB |
| One semantic snapshot | 1 MiB |
| Startup suffix | 1,000 events or 8 MiB |
| Writer admission | 112 normal and 16 control operations |
| Total admitted logical payload | 288 MiB |
| SQLite readers | 16, with 4 reserved |
| Read transaction and busy timeout | 1 second and 250 ms |
| Concurrent and queued recovery | 4 and 124 sessions |
| One recovery diagnostic | 32 entries, 2 KiB each, 64 KiB total |
| One history page | 128 records and 1 MiB |
| Steering and follow-up queues | 128 items each and 8 MiB combined |
| Unresolved interactions and permissions | 64 of each |
| Credential profiles | 64 profiles, 16 versions, 8 references, 16 KiB metadata |

The seven file budgets add to 4 GiB: 1,024 MiB active database, 384 MiB WAL,
16 MiB control files, 1,024 MiB backups, 512 MiB archives, 1,024 MiB shared
maintenance, and 112 MiB unallocated safety. The larger of logical size and
allocated blocks counts against a limit.

Capacity fails before durable acknowledgement. Normal work must preserve the
160 MiB database reserve and 512 MiB tree reserve. The product does not delete
authoritative active state to make space.

## Sensitive-Value Boundary

Product data accepts a credential-profile or credential-reference identity.
It does not accept a credential value. Structural validation rejects
credential fields, inline authorization, URI user data, shell credential
arguments, and credential interpolation before a receipt, event, Jidoka value,
log, trace, artifact, durable write, or execution wake-up can exist.

The stable result is `sensitive_value_rejected`. Its details are bounded and
redacted. At the final provider or tool call, a result that contains the
materialized credential value returns `sensitive_result_blocked`. The product
does not persist the value, its digest, its prefix, its suffix, or its length.

This rule does not claim that the product can find an unknown secret in normal
prompt text. It controls declared credential structures and the exact value
that is materialized for one final call.

## Compatibility Inputs

The versioned M2 compatibility manifest records the exact M2-E37 source,
roadmap, Jidoka, and native payload identities. It also records SHA-256 digests
for the frozen protocol, replay, client, automation, artifact, raw-path, and
fault-isolation inputs. M3 compatibility proof must use these identities. It
must not replace them with a later development checkout.
