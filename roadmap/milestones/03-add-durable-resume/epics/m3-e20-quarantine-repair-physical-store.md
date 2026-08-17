---
epic: M3-E20
type: epic
title: Quarantine and Repair the Physical Store
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e20
depends_on: [M3-E10, M3-E16, M3-E19]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E20: Quarantine and Repair the Physical Store

## Goal

Inspect and repair supported physical store faults without rewriting unverified authoritative history or hiding the original evidence.

## Scope

- Classify physical database, index, manifest, sidecar, mode, chain, and watermark faults.
- Produce a bounded dry-run report before any repair mutation.
- Rebuild only derived indexes and snapshots automatically from verified authoritative records.
- Assign a quarantine identity and report before an explicit authoritative
  repair. Keep the source in the active-store role while the repaired target is
  staged, then move the old source to quarantine only at adoption.
- Use the M3-E19 staged replacement boundary for each supported repair.
- Preserve the original image and evidence until the repaired store verifies.
- Add an explicit, report-bound operation that retires one complete quarantine
  image as one unit. Never rewrite a quarantine image to remove one session.
- Return `repair_required` for unsupported or ambiguous authoritative faults.

## Out of Scope

- Console-to-Jidoka orphan reconciliation
- User-level session repair, retry, or abandon
- Backup creation or general restore
- Archive and per-session removal policy
- Automatic destructive repair

## Dependencies

This epic depends on M3-E10, M3-E16, M3-E19. These dependencies supply immutable Console history, verified watermark checks, and the only safe physical replacement boundary.

## Pull Request Boundary

Deliver this epic in exactly one pull request. It delivers only physical
inspection, dry-run reports, derived rebuild, quarantine, supported repair,
whole-quarantine retirement, and verification. It must not add semantic session
decisions, per-session removal, client, proof, candidate, audit, or publication work.

## Detailed Delivery Plan

### Preconditions

- M3-E10 can rebuild derived snapshots and indexes from verified history.
- M3-E16 can verify or reject Console-to-Jidoka links.
- M3-E19 can stage and adopt a verified replacement while preserving the original.

### Decisions and invariants

- Automatic work can change only derived data.
- Authoritative repair is explicit, supported, dry-run first, and audited.
- Corrupt evidence is preserved in quarantine. The product never creates an empty replacement store.
- Quarantine, staging, and repair share the 1 GiB work pool and one-operation
  limit. The source uses the active budget until adoption. The repaired target
  then becomes active and the prior source becomes the one shared-pool image.
- Whole-quarantine retirement uses the M3-E08 confirmed-retirement control
  class and its exact page, WAL, and control-file allowance.
- Semantic orphan decisions remain in M3-E24.

### Delivery steps

1. Add physical fault classes and bounded dry-run reports.
2. Add derived-index and semantic-snapshot rebuild with digest equivalence.
3. Add quarantine identity, external manifest, private modes, and quota reservations.
4. Add supported authoritative repair transformations with exact preconditions.
5. Use staged replacement, role transition, and final reopen verification.
6. Add exact whole-quarantine report, confirmation, retirement, and repeat results.
7. Add explicit unsupported, ambiguous, and future-schema results.
8. Add corruption, interrupted repair, disk-full, tamper, derived-only, and original-preservation tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Derived fault | Rebuild gives the same canonical projection | Authoritative digests unchanged |
| Supported repair | Staged store verifies before adoption | Exact dry-run and repair IDs |
| Unsupported fault | Typed repair-required result | Original bytes unchanged |
| Repair crash | Original or repaired store remains explicit | No empty store |
| Quarantine | Original image and report remain private and bounded | Shared work-pool limit |
| Quarantine retirement | Complete image is removed or unchanged | Exact image and report digest |

### Completion boundary and handoff

M3-E21 uses these inspection results before classification. M3-E24 can request
only the supported staged physical operations and owns all semantic repair and
abandon decisions. M3-E30 blocks session removal while a whole quarantine image
contains the session and points to this separate whole-image retirement.

### Risks and controls

- Repair can invent authority. Limit it to exact supported transformations with verifiable postconditions.
- Quarantine can consume all disk. Reserve the complete high-water size first.
- A rebuild can hide canonical corruption. Verify authoritative digests before any derived work.

## Acceptance Checks

- Every physical fault has one typed class and bounded dry-run report.
- Automatic repair changes only derived records and produces an equivalent rebuild.
- Authoritative repair is explicit, audited, staged, and verified before adoption.
- The original corrupt image and evidence remain in quarantine until explicit,
  report-bound whole-image retirement.
- Unsupported or ambiguous faults return `repair_required` without mutation.
- Interrupted repair leaves one old or repaired verified authority and no empty store.
- Exactly one staged target or prior source uses the shared 1 GiB work pool;
  the other image uses the active-database budget. All data stays below `JIDO_HOME`.
- Whole-quarantine retirement names the complete image and every covered
  session. It never rewrites that image for one session.
- No semantic orphan, retry, abandon, archive, per-session removal, or client behavior is added.

## Proof Artifacts

- Physical fault and repair matrix
- Bounded dry-run report schema
- Derived rebuild equivalence
- Quarantine manifest and size result
- Interrupted repair matrix
- Original-preservation and final-verification results
- Whole-quarantine retirement report, confirmation, and repeat result

## Milestone Traceability

This epic supplies the physical repair boundary required before recovery can report an exact or blocked session state.
