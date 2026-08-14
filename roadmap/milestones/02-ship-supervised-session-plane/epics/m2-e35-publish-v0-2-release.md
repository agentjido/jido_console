---
epic: M2-E35
type: epic
title: Publish and Record Jido Console v0.2
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e35
depends_on: [M2-E34]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E35: Publish and Record Jido Console v0.2

## Goal

Publish and record the audited Jido Console v0.2 release.

## Scope

- Publish through the protected release workflow after the v0.2 audit approves the exact payload.
- Publish the same tested native payload through every claimed channel.
- Create the immutable version tag and release record.
- Record checksums, provenance, channel results, and partial-publish handling.

## Out of Scope

- A new payload, source commit, or support claim.
- A release when the audit is blocked.
- New platform or channel claims.
- Post-release feature work.

## Dependencies

This epic depends on M2-E34 for the approved audit of the exact v0.2 source and payload.

## Pull Request Boundary

Deliver this epic in exactly one release pull request. The pull request binds the audited source and payload and invokes the protected release workflow after merge. The workflow publishes and records only the audited v0.2 payload. The pull request must not claim publication before the workflow succeeds.

## Acceptance Checks

- The protected release workflow accepts only the source and payload approved by M2-E34.
- Every claimed channel receives the same tested native payload, version, checksums, and provenance.
- The immutable v0.2 tag and release record identify the exact source and payload.
- Partial publish failure has a recorded stop, repair, or rollback path.
- The published release record links the roadmap milestone, epics, proof, audit, and channel evidence.
- The release record states that accepted input can be lost on an application crash before Milestone 3.

## Proof Artifacts

- Protected-workflow publication record.
- Immutable tag and release record.
- Channel publication evidence.
- Checksums and provenance record.
- Partial-publish handling record.

## Milestone Traceability

This epic owns the Milestone 2 release effect: publish and record Jido Console v0.2.
