---
epic: M3-E08
type: epic
title: Add Early Store Quota Primitives
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e08
depends_on: [M3-E07]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E08: Add Early Store Quota Primitives

## Goal

Enforce the complete file-tree budget and reserve maintenance capacity before later durable features can write data.

## Scope

- Account for the active database, WAL, control files, backups, archives, staging, quarantine, repair, and temporary files under the versioned state root.
- Enforce the exact sub-budgets that sum to the 4 GiB state-tree limit.
- Stop normal tree admission at 3.5 GiB and preserve the last 512 MiB for declared maintenance operations.
- Reserve worst-case source and destination bytes before an operation enters the writer.
- Count the larger of logical file size and allocated blocks so sparse files cannot bypass a limit.
- Reconcile each reservation to measured final bytes and release it after commit, rollback, or cleanup.
- Return typed database-page, WAL, sub-budget, tree, temporary-data, and maintenance-capacity results before acknowledgement.

## Out of Scope

- Backup, migration, restore, repair, archive, or removal workflows
- Retention decisions
- Session generation or canonical events
- Storage-engine selection
- Client behavior

## Dependencies

This epic depends on M3-E07. This dependency supplies the only writer, home lock, path checks, and bounded admission lanes used by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only quota accounting, reservation, and typed capacity results. It must not add a maintenance workflow, client change, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E07 owns every writable connection and every product-created state path.
- M3-E01 freezes the exact byte, page, file, count, and reserve values.
- M3-E06 can report database pages, freelist pages, and intrinsic record sizes.

### Decisions and invariants

- The state-tree budget is a correctness rule, not an alert threshold.
- The seven hard sub-budgets sum to exactly 4,096 MiB.
- Normal operations cannot consume the 160 MiB database control-page reserve or final 512 MiB tree reserve.
- Only cancellation, safe completion, checkpoint finalization, recovery,
  bounded audit-export metadata, confirmed session removal, confirmed
  whole-backup or whole-quarantine retirement, and shutdown use control capacity.
- One confirmed removal or retirement can reserve at most 1 MiB of new database
  pages, 256 MiB of WAL, and 8 MiB of control files. It starts below the 64 MiB
  WAL stop and cannot exceed the 384 MiB WAL or 4 GiB tree limit.
- An operation that cannot reserve its worst-case high-water bytes does not start.
- Quota accounting cannot delete, compact, archive, or repair data. Later epics own those decisions.

### Delivery steps

1. Add typed quota classes, operation classes, reservations, and final-use measurements.
2. Add database page and WAL high-water accounting to writer admission.
3. Add file-tree accounting by sub-budget, logical size, and allocated blocks.
4. Add atomic reserve, commit, rollback, expiry, and recovery of reservations.
5. Add startup reconciliation for abandoned reservations and actual files.
6. Add normal and control admission rules with explicit allowed operation kinds.
7. Add sparse-file, concurrent-reservation, crash, disk-full, and exact-boundary tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Normal database work | Admission stops and leaves control pages | 864 MiB normal; 160 MiB reserve |
| Normal tree work | Admission stops and leaves maintenance space | 3.5 GiB normal; 512 MiB reserve |
| Sub-budget | One full category cannot borrow hidden space | Exact category and typed result |
| Sparse file | Allocated blocks or logical size is charged, whichever is larger | No limit bypass |
| Crash after reserve | Startup reconciles the reservation to durable state | Same operation identity |
| Staged work | Source and destination high-water bytes both count | No temporary overrun |
| Confirmed removal or retirement | One confirmed operation can free data without normal capacity | 1 MiB pages; 256 MiB WAL; 8 MiB control files |

### Completion boundary and handoff

M3-E09 uses the quota operation identity in every generation claim. M3-E10 and all later mutation epics use this quota API. M3-E17 through M3-E20 and M3-E29 through M3-E30 add workflows, not new quota owners.

### Risks and controls

- A size estimate can be too small. Use a conservative maximum and reconcile after the operation.
- A file can change outside the writer. Recheck owned file identity and size before commit.
- A control label can become a bypass. Use a closed operation-kind allow-list and test every denied kind.

## Acceptance Checks

- The active database, WAL, control, backup, archive, shared work, and structural-safety budgets sum to 4 GiB.
- Normal admission cannot consume the database or tree control reserve.
- Every state file is charged by the larger of logical and allocated size.
- Every operation reserves its worst-case high-water bytes before it enters the writer.
- Concurrent and crashed reservations cannot over-admit work or leak capacity permanently.
- A full category or tree returns a typed result before a durable acknowledgement candidate exists.
- Control capacity is available only to the declared closed set of operations,
  including the exact bounded confirmed-removal class.
- No backup, migration, restore, repair, archive, removal, or product compaction behavior is added.

## Proof Artifacts

- State-tree and sub-budget table
- Database-page and WAL reservation result
- Normal and control operation matrix
- Sparse-file and staged-copy measurements
- Concurrent and crash reservation results
- Typed capacity fixture set

## Milestone Traceability

This epic establishes the early hard-cap primitive that keeps the file-based store bounded for the full product life cycle.
