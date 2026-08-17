---
epic: M3-E18
type: epic
title: Migrate the Durable Store
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e18
depends_on: [M3-E03, M3-E08, M3-E17]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E18: Migrate the Durable Store

## Goal

Move each supported old store to one verified current schema without changing an unknown or unprotected source.

## Scope

- Inspect store format, schema, migration ledger, checksums, and integrity before a write.
- Reject an unknown future version before mutation.
- Require a verified M3-E17 pre-migration backup before the first migration write.
- Run ordered, checksummed, idempotent migrations under the writer and quota barrier.
- Verify schema, ledger, record counts, chain heads, watermarks, indexes, limits, and modes after each migration plan.
- Resume or stop an interrupted migration from its durable ledger state.
- Enforce the 120-second migration guard and typed blocked result.

## Out of Scope

- General backup creation
- Restore or live-store replacement
- Physical corruption repair
- Semantic session repair
- Client or session recovery behavior

## Dependencies

This epic depends on M3-E03, M3-E08, M3-E17. These dependencies supply deterministic migration definitions, high-water quota reservations, and a verified pre-migration backup.

## Pull Request Boundary

Deliver this epic in exactly one pull request. It delivers only schema inspection, migration planning, execution, verification, and interrupted-migration handling. It must not add restore, repair, session recovery, client, proof, candidate, audit, or publication work.

## Detailed Delivery Plan

### Preconditions

- M3-E03 defines every supported source, target, checksum, and transformation.
- M3-E17 can create and identify one verified backup.
- M3-E08 can reserve the migration high-water size.

### Decisions and invariants

- A future or unknown schema fails before any write.
- No migration starts without a verified backup of the exact source store.
- Each migration has one source, target, checksum, precondition, transaction, and postcondition.
- A second successful run makes no change.
- A timeout is a typed migration state. It does not create an empty store or report readiness.

### Delivery steps

1. Add startup schema inspection and a deterministic migration plan.
2. Bind the plan to the exact source store and verified backup identities.
3. Add quota and temporary-work reservations.
4. Run ordered migrations and commit ledger entries under the writer.
5. Verify the complete target after each plan.
6. Add interrupted-ledger resume and explicit blocked states.
7. Add old, current, future, checksum, timeout, disk-full, crash, and second-run tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Supported old store | One current verified target opens | Exact migration checksums |
| Future schema | Typed incompatible result before write | Source digest unchanged |
| No backup | Migration does not start | Exact source remains valid |
| Crash | Old or migrated state is identified by ledger | No partial ready state |
| Second run | No schema or data change | Same target digest |

### Completion boundary and handoff

M3-E19 can restore a verified source and then use this migration contract. The
store-wide startup gate runs M3-E18 once before M3-E21 starts catalog recovery.

### Risks and controls

- A migration can change unknown data. Fail on unknown fields and versions.
- An interrupted migration can look current. Verify ledger and postconditions together.
- Maintenance can exceed disk limits. Reserve the worst-case work pool before start.

## Acceptance Checks

- Every supported migration is ordered, checksummed, idempotent, and transaction safe.
- A verified backup of the exact source exists before the first migration write.
- Unknown future schema or checksum mismatch fails before mutation.
- Interrupted migration has one durable resume or blocked result.
- Post-migration verification covers schema, ledger, heads, watermarks, counts, indexes, limits, and modes.
- Migration temporary work stays below `JIDO_HOME` and within the shared work pool.
- Migration stops at its 120-second runtime guard without a false ready result.
- No restore, repair, session recovery, or client behavior is added.

## Proof Artifacts

- Migration compatibility and order matrix
- Source-to-backup identity link
- Migration ledger and checksum report
- Interrupted migration matrix
- Future-schema and second-run results
- Temporary-file and high-water inventory

## Milestone Traceability

This epic supplies the explicit version-change gate required before durable sessions recover.
