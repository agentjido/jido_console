---
epic: M3-E19
type: epic
title: Restore the Durable Store
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e19
depends_on: [M3-E08, M3-E17, M3-E18]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E19: Restore the Durable Store

## Goal

Replace the stopped live store with one fully verified local store while preserving the prior valid image until adoption completes.

## Scope

- Stop session and writer ownership before restore staging.
- Keep the source charged to the verified-backup budget, the current live store
  charged to the active-database budget, and only the staged target charged to
  the shared work pool. Reserve the complete tree high-water bytes.
- Accept only a local verified SQLite backup and matching manifest below the Jido state root.
- Verify format, schema, migration path, integrity, counts, chain heads, watermarks, digests, modes, and path identity.
- Stage and migrate the incoming image before it can become live.
- Use the M3-E07 maintenance owner and external operation manifest for a
  crash-safe same-file-system rename sequence. Preserve the prior live store
  until the replacement opens and verifies.
- Recover an interrupted restore to one old or new verified authority.

## Out of Scope

- Creating backups
- General schema-migration implementation
- Repairing a corrupt incoming store
- Remote restore sources
- Session semantic repair

## Dependencies

This epic depends on M3-E08, M3-E17, M3-E18. These dependencies supply the quota barrier, verified backup format, and supported migration path required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. It delivers only stopped-store verification, staging, replacement, rollback, and interrupted-restore handling. It must not add backup, physical repair, session recovery, client, proof, candidate, audit, or publication work.

## Detailed Delivery Plan

### Preconditions

- The application can stop session mutation and the writer under the home lock,
  then transfer exclusive file ownership to the M3-E07 maintenance coordinator.
- M3-E17 identifies a verified local backup and manifest.
- M3-E18 can bring supported incoming schema to the current target.

### Decisions and invariants

- Restore never overwrites the only known valid image before the staged target verifies.
- Source and destination must be regular private files on the same owned file system.
- Use rename for the authority switch. Do not create an unnecessary second copy.
- Before adoption, live uses the active budget, source uses the backup budget,
  and stage uses the shared budget. During adoption, the operation manifest
  changes roles so new live uses the active budget and prior live uses the
  shared budget. At no point do two images use the shared budget.
- A restored store is not ready until it reopens under the production pragmas and passes final verification.
- A failed or interrupted restore leaves one explicit old or new authority and a durable administrative record.

### Delivery steps

1. Add stopped-writer restore mode and an external durable restore operation identity.
2. Verify the incoming database and manifest before staging.
3. Reserve high-water bytes and stage the incoming image under the state root.
4. Run required migration and complete target verification.
5. Switch authority through the manifest-driven same-file-system rename and role-transition sequence while preserving the prior image.
6. Reopen and verify the new live store, then record adoption or rollback.
7. Add crash, power-loss, disk-full, mode, link, cross-file-system, corrupt, future-schema, and rollback tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Valid restore | New live store matches incoming verified heads | Exact restore operation identity |
| Invalid input | Live store remains unchanged | No adoption record |
| Crash before switch | Old live store remains authority | Staging is non-authoritative |
| Crash after switch | New store verifies or old store rolls back | One explicit authority |
| Capacity | Restore does not start without complete tree and category space | Source in backup; live in active; stage in shared |

### Completion boundary and handoff

M3-E20 uses this staged replacement boundary for supported physical repair. M3-E21 opens only a fully adopted and migrated store.

### Risks and controls

- A replacement can lose both copies. Preserve the old image through final reopen verification.
- A cross-file-system move is not atomic. Reject it before staging.
- An incoming store can hide a future schema. Inspect and migrate before adoption.

## Acceptance Checks

- Restore runs only while the session tree and writer are stopped under the home lock.
- Incoming data verifies before staging and again before and after adoption.
- The source stays in the backup budget, the current authority stays in the
  active budget, and only one staged or prior image uses the shared work pool.
- The complete tree high-water size fits before restore starts.
- The prior live image remains available until the replacement reopens and verifies.
- The authority switch uses a manifest-driven same-file-system rename sequence
  and has one durable adoption or rollback record outside the replaced database.
- Every crash point leaves one explicit valid authority and no empty replacement store.
- All restore files stay below `JIDO_HOME/state/sessions/v1` with private modes.
- No backup, physical repair, session recovery, or client behavior is added.

## Proof Artifacts

- Restore state machine and operation record
- Incoming verification report
- High-water and same-file-system proof
- Replacement and reopen trace
- Interrupted restore and rollback matrix
- Final state-root inventory

## Milestone Traceability

This epic supplies the reversible local restore operation required by the durable-session life cycle.
