---
epic: M2-E34
type: epic
title: Audit the v0.2 Release
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e34
depends_on: [M2-E01, M2-E02, M2-E03, M2-E04, M2-E05, M2-E06, M2-E07, M2-E08, M2-E09, M2-E10, M2-E11, M2-E12, M2-E13, M2-E14, M2-E15, M2-E16, M2-E17, M2-E18, M2-E19, M2-E20, M2-E21, M2-E22, M2-E23, M2-E24, M2-E25, M2-E26, M2-E27, M2-E28, M2-E29, M2-E30, M2-E31, M2-E32, M2-E33]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E34: Audit the v0.2 Release

## Goal

Make the final evidence-only decision for the v0.2 release candidate.

## Scope

- Audit all Milestone 2 epic evidence and the common release-gate evidence.
- Verify the exact source identity, native payload identity, checksums, provenance, and support claims.
- Record unresolved defects, known limits, and the final release decision.
- Link the audit to the Milestone 2 delivery graph and proof artifacts.

## Out of Scope

- Code changes that alter the release candidate.
- Production publication.
- New feature, packaging, or support claims.
- Replacing missing evidence with a demonstration from a development checkout.

## Dependencies

This epic depends on every Milestone 2 epic from M2-E01 through M2-E33 because the release decision needs their completed evidence.

## Pull Request Boundary

Deliver this epic in exactly one audit-only pull request. The pull request records the release decision and evidence only. It must not publish v0.2 or change the candidate payload.

## Acceptance Checks

- Every M2-E01 through M2-E33 proof artifact is linked and reviewed.
- The audit names the exact source commit, artifact checksum, payload identity, and tested platform-by-channel cells.
- The audit verifies the common release gate and the Milestone 2 exit gate.
- The audit records known limits, unresolved defects, and the explicit crash-loss limit.
- The audit result is an approved release decision or a clear blocked decision.

## Proof Artifacts

- v0.2 release audit record.
- Exact source and payload identity record.
- Complete Milestone 2 evidence index.
- Release decision and known-limit record.

## Milestone Traceability

This epic covers the evidence-only final audit of the Milestone 2 v0.2 release candidate.
