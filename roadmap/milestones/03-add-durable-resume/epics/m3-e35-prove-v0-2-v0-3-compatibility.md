---
epic: M3-E35
type: epic
title: Prove v0.2-to-v0.3 Compatibility
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e35
depends_on: [M3-E05, M3-E17, M3-E18, M3-E19, M3-E27, M3-E28, M3-E31, M3-E33]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E35: Prove v0.2-to-v0.3 Compatibility

## Goal

Prove the exact compatibility boundary from the approved v0.2 baseline to the first durable v0.3 store and clients.

## Scope

- Freeze the M2-E37 source, protocol, semantic replay, client, automation, and artifact fixture digests.
- Prove that a clean v0.2 Jido home upgrades without inventing durable sessions.
- Prove current and supported older v0.3 storage schemas, migration, backup, restore, and interrupted migration.
- Prove that a future or corrupt schema fails without a write or empty replacement.
- Prove the exact Jidoka pin, session schema, snapshot schema, and store-adapter compatibility.
- Preserve automation schemas, JSONL ownership, artifacts, and exit statuses.
- Prove bounded additive protocol handling and no raw runtime path.

## Out of Scope

- Product compatibility fixes
- Support for an unlisted schema or platform
- Downgrade in place
- Candidate packaging
- Publication

## Dependencies

This epic depends on M3-E05, M3-E17, M3-E18, M3-E19, M3-E27, M3-E28, M3-E31, M3-E33. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M2-E37 names one exact approved baseline.
- M3-E05 pins the qualified Jidoka source.
- M3-E17 through M3-E19 supply separate backup, migration, and restore fixtures.
- M3-E33 proves the current functional workflow.

### Decisions and invariants

- A v0.2 home has no durable-session database unless one was created by v0.3. Upgrade does not infer sessions from process-local history.
- Migration is one-way. Downgrade in place is not supported.
- Exact resume is unavailable when Jidoka or storage compatibility cannot be proved.
- Unknown additive protocol data remains bounded and non-authoritative.
- This is compatibility proof only; defects return to their owning epic.

### Delivery steps

1. Create the immutable compatibility-input manifest.
2. Add clean v0.2 home and frozen protocol/client/automation fixtures.
3. Add current, earlier, future, interrupted, corrupt, backup, and restore store fixtures.
4. Add exact Jidoka schema, codec, checkpoint, and adapter fixtures.
5. Run all client and automation compatibility cases.
6. Run raw-path, unknown-data, and no-empty-replacement guards.
7. Record the compatibility decision matrix.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Clean v0.2 home | v0.3 starts with no invented session | Existing retained data preserved |
| Storage revisions | Supported versions migrate to same digest | Future version makes no write |
| Jidoka | Exact pin and schemas restore known fixtures | Mismatch blocks exact resume |
| Clients and automation | Frozen contracts pass | JSONL and exit status unchanged |
| Unknown or corrupt data | Bounded preserve or typed rejection | No authority or empty replacement |

### Completion boundary and handoff

M3-E36 builds one candidate only after this compatibility proof and M3-E34 crash proof both pass.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- Every compatibility input is identified by digest.
- A clean v0.2 home upgrades without invented durable sessions or lost retained data.
- Every supported v0.3 schema migrates to the same verified result.
- Future and corrupt schemas fail before mutation.
- Interrupted migration preserves one valid store.
- The exact Jidoka pin, session, snapshot, checkpoint, and adapter fixtures pass.
- M2 protocol, client, automation, JSONL, artifact, and exit-status contracts remain compatible.
- Exact resume is not claimed when compatibility is missing.
- No product behavior is changed.

## Proof Artifacts

- Compatibility-input manifest
- Clean v0.2 home result
- Storage migration and future-schema matrix
- Backup and restore digest comparison
- Jidoka compatibility result
- M2 client and automation fixture results
- Raw-path and unknown-data guards

## Milestone Traceability

This epic protects the approved Milestone 2 baseline while introducing the first durable store.
