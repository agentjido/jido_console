---
epic: M3-E30
type: epic
title: Remove Durable Sessions Explicitly
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e30
depends_on: [M3-E26, M3-E29]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E30: Remove Durable Sessions Explicitly

## Goal

Delete one stopped session from the active store and session-specific retained
data only after an exact dependency report and explicit confirmation.

## Scope

- Build a dry-run report of active rows, backups, archives, quarantine sets, manifests, artifacts, fork parents, fork children, and retained audit links for one session.
- Bind a short-lived confirmation token to the exact report digest, session identity, generation, and requested removal scope.
- Refuse removal while an undeclared fork or required ancestry dependency exists.
- Refuse removal while a retained whole-store backup or quarantine image contains
  the session. Report the separate M3-E17 or M3-E20 whole-image retirement operation.
- Require a terminal or abandoned session, detach clients, fence the session
  generation, stop its owner, drain or reject writes, and acquire the writer
  maintenance barrier before the final report check.
- Purge only the confirmed active rows, session-specific archives, manifests,
  artifacts, and exact owned files below the Jido home.
- Preserve a bounded tombstone or audit anchor so an old session identity cannot silently become a new session.
- Make an exact repeated removal idempotent and reject a stale or changed report.
- Prove that unrelated home, session, backup, quarantine, archive, and artifact
  data does not change.

## Out of Scope

- Home-wide removal
- Automatic retention deletion
- Remote copies not owned by Jido Console
- Archive creation
- Replacement behavior
- Rewriting or partly deleting a whole-store backup or quarantine image
- Whole-backup or whole-quarantine retirement, which remains in M3-E17 and M3-E20

## Dependencies

This epic depends on M3-E26 and M3-E29. These dependencies supply complete fork lineage and the verified active-or-archive ownership state required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. It delivers only the removal report, confirmation, exact purge, tombstone, and idempotency behavior. It must not add archive, client, proof, candidate, audit, publication, or replacement behavior.

## Detailed Delivery Plan

### Preconditions

- M3-E26 supplies durable parent, child, and fork-boundary identities.
- M3-E29 supplies exact active and archived authority locations.
- The existing retained-user-data confirmation pattern is available.

### Decisions and invariants

- Removal is the only destructive session-life-cycle operation in Milestone 3.
- A shared whole-store image is indivisible. This operation blocks until no such
  image contains the selected session; it never rewrites or deletes that image.
- Removal runs only for a stopped terminal or abandoned session under both the
  session fence and writer maintenance barrier.
- A report and confirmation cover exact resolved identities. A wildcard, unresolved path, or changed dependency stops removal.
- Session IDs are database keys. They never become untrusted file paths.
- The tombstone or audit anchor is bounded, contains no removed content, and prevents silent identity reuse.
- No removal command can target `JIDO_HOME`, a retained root, or more than one selected session.

### Delivery steps

1. Add the exact removal-scope and dependency-report values.
2. Resolve active, archived, backup, quarantine, artifact, and fork references without mutation, and classify shared images as blockers.
3. Add the report-bound confirmation token and stale-report checks.
4. Add detach, generation fence, stopped-owner, writer-barrier, and final-report recheck.
5. Add the ordered purge under the home lock and quota owner with the confirmed-removal control allowance.
6. Add the bounded tombstone or audit anchor and exact repeat result.
7. Add unrelated-data guards and path-ownership checks.
8. Add fork, shared-image, active-owner, stale token, partial failure, restart, repeated command, full-store, and unrelated-home tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Dry run | Report lists every owned copy and dependency | Exact session and report digest |
| Fork dependency | Removal is denied before mutation | Child and parent remain valid |
| Shared store image | Removal is denied and names whole-image retirement | Backup or quarantine unchanged |
| Active owner | Detach, fence, stop, and barrier complete first | Final report and generation match |
| Confirmed purge | Only listed data is removed | Token matches report and scope |
| Partial failure | Restart resumes or reports exact remaining items | No unrelated deletion |
| Repeat | Same confirmed operation returns terminal result | Identity is not reused |

### Completion boundary and handoff

M3-E31 exposes this operation through the existing confirmation pattern. M3-E33
proves exact session-specific deletion, shared-image blocking, control-capacity
use, and unrelated-data preservation. No later epic can add a broader deletion
target without a roadmap change.

### Risks and controls

- A path can resolve outside the home. Require owned regular-file identity before each file mutation.
- A dependency can change after the report. Recheck the report digest and generation under the lock.
- Partial deletion can hide remaining data. Record and return each completed and remaining exact item.
- A full store can block the operation needed to free space. Use only the frozen
  control allowance: at most 1 MiB new database pages, 256 MiB WAL, and 8 MiB
  control files, with a checkpoint below 64 MiB before purge.

## Acceptance Checks

- Removal starts with a complete exact dependency and owned-data report.
- The confirmation token is bound to the report digest, session, generation, and scope.
- A fork or ancestry dependency blocks unsafe removal before mutation.
- A retained whole-store backup or quarantine image blocks removal and stays unchanged.
- The session is terminal or abandoned, all clients detach, the old generation
  is fenced, the owner stops, and the writer barrier is held before purge.
- Only the confirmed session rows and session-specific owned files change.
- Confirmed removal can use its exact bounded control allowance at the normal
  capacity stop, but cannot exceed the WAL or complete-tree hard limit.
- Partial failure and restart report the exact completed and remaining items.
- A repeated exact removal is idempotent.
- A bounded tombstone or audit anchor prevents silent session-ID reuse.
- The operation cannot target a broad directory, another session, or unrelated Jido home data.

## Proof Artifacts

- Removal report and scope schema
- Confirmation-token binding result
- Fork-dependency denial matrix
- Exact purge and repeat result
- Partial-failure recovery report
- Unrelated-data and path-ownership proof

## Milestone Traceability

This epic isolates the only destructive session operation and gives it an exact, auditable, dependency-aware boundary.
