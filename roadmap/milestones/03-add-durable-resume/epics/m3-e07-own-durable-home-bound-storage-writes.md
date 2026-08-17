---
epic: M3-E07
type: epic
title: Own the Durable Home and Bound Storage Writes
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e07
depends_on: [M3-E06]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E07: Own the Durable Home and Bound Storage Writes

## Goal

Give the durable home one supervised owner, one bounded write path, and a safe startup and failure boundary.

## Scope

- Add the storage supervisor, Jido home lock, bounded admission counters, one
  SQLite writer, one maintenance coordinator, and one store-wide migration and
  integrity gate.
- Start storage before recovery and session supervision with rest-for-one ordering.
- Reserve operation count and copied payload bytes before sending to the writer.
- Use 112 normal and 16 control operation slots, a 16 MiB small-payload pool, one 136 MiB normal large lane, one 136 MiB control large lane, and one transaction in flight.
- Return typed busy, unavailable, timeout-unknown, capacity, permission, lock, and integrity results.
- Keep one transaction in flight and reserve capacity for recovery, cancellation, checkpoint finalization, bounded audit-export metadata, and shutdown.
- Validate every owned file and sidecar with private permissions and no symbolic-link escape.
- Add a bounded external maintenance-manifest writer for operations that must
  stop or replace the SQLite writer-owned store.
- Stop normal session mutation when the writer or home lock is unavailable.
- Apply the 250 ms SQLite busy timeout, 1-second public deadline, reader-age rule, and WAL checkpoint state machine.

## Out of Scope

- Durable session generation semantics
- Canonical event persistence from Session.Server
- Recovery lifecycle
- Backup or archive operations
- Client behavior

## Dependencies

This epic depends on M3-E06. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E06 passes repository conformance and has no direct production callers.
- The M1 Jido home contract and private-permission behavior are stable.

### Decisions and invariants

- A public API reserves count and bytes before a request can enter the private writer mailbox.
- The writer PID and writable database connection are never exposed.
- A timeout does not mean failure. The caller receives the operation ID and queries the committed result.
- A second application cannot write the same home. Lock failure is a typed startup result.
- Storage work never runs inside `Session.Server`.
- The maintenance coordinator is the only file-tree mutation owner while the
  SQLite writer is stopped. Its 64 KiB canonical manifest is written as a
  private temporary file, synced, renamed on the same file system, and followed
  by a parent-directory sync.
- Startup reconciles an incomplete maintenance manifest before SQLite opens.
- No message enters the writer until its lane, payload, worst-case database pages, and worst-case WAL bytes are reserved.
- At 64 MiB of WAL or one busy interval, normal writes stop. At a persistent blocked checkpoint, all page-adding writes stop and storage recovery owns the intact WAL.

### Delivery steps

1. Add the storage supervision subtree, maintenance coordinator, and rest-for-one application order.
2. Add the private home lock and stale-lock crash tests.
3. Add atomic normal/control slot, small-payload, large-lane, page, and WAL admission.
4. Add the one-connection writer and operation-result lookup.
5. Add safe path, mode, sidecar, state-root, and external maintenance-manifest checks.
6. Add persistent-reader, checkpoint-busy, writer death, caller death, timeout, disk-full, lock, and restart tests.
7. Measure mailbox, admitted bytes, in-flight work, reader age, WAL, and response bounds.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Stopped writer | Public callers cannot exceed count or byte admission | Writer mailbox and copied payload stay bounded |
| Second application | Home lock denies the second writer | First owner remains valid |
| Commit before reply | Operation lookup returns the committed receipt | Retry does not duplicate |
| Writer death | Session mutation stops and subtree restarts | No false acknowledgement |
| Unsafe path | Symlink, mode, sidecar, or external path fails closed | No file created outside the state root |
| Checkpoint busy | Normal then page-adding writes stop at declared states | WAL stays at or below 384 MiB |
| Large lanes | One normal and one control Jidoka request can be admitted | Total logical payload at or below 288 MiB |
| Stopped-store operation | Maintenance manifest recovers before SQLite opens | 64 KiB; one exact operation identity |

### Completion boundary and handoff

M3-E08 adds full state-tree quota reservations through this write path. M3-E09
and later epics use only the bounded storage API and quota contract. M3-E17
through M3-E20 and M3-E29 through M3-E30 use the maintenance coordinator for
their declared stopped-writer phases; they do not add another owner or journal.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- Only one supervised process owns the writable SQLite connection.
- The writer mailbox, admitted operation count, copied payload bytes, and in-flight transaction count stay within limits.
- The exact normal/control slots, small pool, large lanes, and 288 MiB total logical-payload bound hold with a stopped writer.
- A busy or unavailable writer returns a typed result before durable acknowledgement.
- The 250 ms busy timeout and 1-second public deadline return a resolvable `timeout_unknown` result without a false rollback claim.
- A second application cannot write the same Jido home.
- All store files and sidecars stay under the private state root.
- A writer crash or lock loss stops normal mutation and triggers ordered recovery.
- Persistent readers cannot grow the WAL without bound, and a blocked checkpoint preserves the intact WAL for recovery.
- Session and recovery code cannot access the writable connection directly.
- A stopped-store operation has one supervised owner and one crash-safe external
  manifest that startup reconciles before it opens SQLite.

## Proof Artifacts

- Storage supervision diagram
- Home-lock process tests
- Stopped-writer mailbox and payload measurements
- Commit-before-reply idempotency result
- Writer crash and restart result
- Path, permission, and sidecar inventory
- Maintenance-manifest crash and sync trace

## Milestone Traceability

This epic establishes the BEAM ownership and backpressure boundary required for safe file-only durability.
