---
epic: M3-E17
type: epic
title: Back Up and Verify the Durable Store
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e17
depends_on: [M3-E07, M3-E08, M3-E10, M3-E16]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.5
---

# M3-E17: Back Up and Verify the Durable Store

## Goal

Create one consistent, private, bounded, and verified local backup without copying an open database as ordinary files.

## Scope

- Use a writer-owned barrier and SQLite `VACUUM INTO` to create one
  transactionally consistent snapshot through the selected adapter's SQL path.
- Reserve source-plus-destination high-water bytes before backup starts.
- Write a manifest with source store identity, schema, chain heads, watermarks, record counts, file digest, size, and private modes.
- Verify the completed database and manifest before the backup becomes usable.
- Keep at most three automatic backup files and 1 GiB of verified backups in total.
- Rotate only surplus verified automatic backups before a new automatic backup.
- Add an explicit, report-bound operation that retires one verified whole-store
  backup as one unit. Never rewrite a backup to remove one session.
- Recover interrupted backup staging without changing the live store.
- Keep every backup, manifest, and temporary file below the versioned Jido state root.

## Out of Scope

- Schema migration
- Restore or replacement of the live store
- Corruption repair
- Archive or removal of one session from a shared backup
- External backup destinations

## Dependencies

This epic depends on M3-E07, M3-E08, M3-E10, M3-E16. These dependencies supply the only writer, quota reservations, canonical heads, and verified watermark data required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. It delivers only consistent
backup creation, verification, rotation, whole-backup retirement, and
interrupted-backup cleanup. It must not add migration, restore, repair, archive,
session removal, client, candidate, audit, or publication work.

## Detailed Delivery Plan

### Preconditions

- M3-E07 owns the writable connection and home lock.
- M3-E08 can reserve the complete backup high-water size.
- M3-E10 and M3-E16 supply exact canonical and cross-store heads.

### Decisions and invariants

- A raw copy of an open database is not a backup. Do not require an adapter C
  backup API.
- The live source remains authoritative throughout backup.
- A staged backup is not usable until database and manifest verification pass.
- Three files are a count ceiling. All verified backups together stay at or below 1 GiB.
- Backup rotation never removes the last verified automatic backup before its replacement verifies.
- A verified backup is an indivisible store image. Retirement reports every
  covered session and removes the complete image only after report-bound
  confirmation.
- Whole-backup retirement uses the M3-E08 confirmed-retirement control class
  and its exact page, WAL, and control-file allowance.

### Delivery steps

1. Add writer backup barriers and one backup operation identity.
2. Add quota reservation for the source and staged destination high-water size.
3. Add SQLite `VACUUM INTO` into a new private staging path under the state
   root.
4. Add manifest creation and full database, schema, head, watermark, count, digest, and mode verification.
5. Adopt the verified backup atomically and rotate surplus verified automatic backups.
6. Add exact whole-backup report, confirmation, retirement, and repeat results.
7. Add interrupted staging discovery and bounded cleanup.
8. Add live-write, disk-full, permission, writer-death, verification-failure, and exact-limit tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Live backup | Reopened backup has the same verified heads | Exact source operation identity |
| Concurrent write | Backup is one consistent SQLite view | Writer resumes after barrier |
| Capacity | Backup does not start without high-water space | 1 GiB aggregate backup budget |
| Crash | Live store remains authoritative | Partial staging is not adopted |
| Rotation | New backup verifies before an old backup is removed | At least one valid copy remains |
| Explicit retirement | Complete backup is removed or unchanged | Exact backup and report digest |

### Completion boundary and handoff

M3-E18 requires one verified pre-migration backup. M3-E19 uses the same
verification format for incoming restore data. M3-E30 blocks session removal
while any verified whole-store backup contains that session and points to this
separate whole-backup retirement operation. No later epic can bypass the backup
barrier or rewrite a shared backup in place.

### Risks and controls

- Backup can appear complete before all pages copy. Reopen and verify the final database.
- Rotation can remove the only good copy. Adopt the new copy before rotation.
- Staging can exceed the tree limit. Reserve source and destination high-water bytes first.

## Acceptance Checks

- Live backup uses SQLite `VACUUM INTO` under writer ownership and produces a
  transactionally consistent snapshot.
- The source remains authoritative and writable only after the barrier releases.
- A backup becomes usable only after full database and manifest verification.
- Automatic backups stay at or below three files and 1 GiB aggregate.
- Explicit retirement acts on one verified whole backup, names every covered
  session, requires report-bound confirmation, and never rewrites the image.
- One full-size backup that cannot fit blocks backup and later migration before any store change.
- Interrupted, corrupt, or incomplete staging cannot replace or invalidate the live store.
- Every backup file stays below `JIDO_HOME/state/sessions/v1` with mode `0600`.
- No migration, restore, repair, archive, or per-session removal behavior is added.

## Proof Artifacts

- Writer backup-barrier trace
- Backup manifest and verification report
- Live-write consistency result
- High-water and rotation measurements
- Whole-backup retirement report and confirmation result
- Interrupted backup matrix
- State-root file inventory

## Milestone Traceability

This epic supplies the verified backup boundary required before migration, restore, and candidate qualification.
