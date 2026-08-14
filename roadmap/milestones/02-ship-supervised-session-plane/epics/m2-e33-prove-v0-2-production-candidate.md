---
epic: M2-E33
type: epic
title: Prove the v0.2 Production Candidate
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e33
depends_on: [M2-E32]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E33: Prove the v0.2 Production Candidate

## Goal

Prove the complete v0.2 release claim through the exact production artifact.

## Scope

- Build and test the exact production artifact through the common release gate.
- Test every platform-and-channel pair claimed by v0.2, including each retained v0.1 cell, with the same v0.2 native payload.
- Run all earlier release workflows and compatibility fixtures against the exact candidate.
- Prove session detach and attach, failure handling, cancellation, cleanup, and client recovery.
- Publish a quick start, support matrix, known limits, security boundary, and rollback or repair path.
- State explicitly that accepted input can be lost on an application crash before Milestone 3.

## Out of Scope

- Production publication.
- Application-restart recovery or a durable input receipt.
- New platform or channel claims.
- New client surfaces.

## Dependencies

This epic depends on M2-E32 because the production candidate must contain only the supervised session path.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request creates and verifies a production candidate. It does not publish the release.

## Acceptance Checks

- The common milestone release gate passes through the exact production artifact.
- Every platform-and-channel pair claimed by v0.2 installs, starts, updates, and removes the same tested native payload.
- All earlier release workflows and compatibility fixtures pass against the candidate.
- Detach and attach, failure, cancellation, worker drain, and cleanup evidence pass through the artifact.
- The quick start, support matrix, known limits, security boundary, and rollback or repair path are runnable and current.
- Documentation states the explicit pre-Milestone-3 crash-loss limit.

## Proof Artifacts

- Production artifact and checksum.
- Platform-by-channel acceptance results.
- Session detach and attach evidence.
- Failure, cleanup, and recovery evidence.
- Quick-start and support documentation review.

## Milestone Traceability

This epic covers the Milestone 2 production-candidate proof for the v0.2 release claim.
