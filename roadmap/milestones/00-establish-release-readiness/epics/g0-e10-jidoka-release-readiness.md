---
epic: G0-E10
type: epic
title: Define Jidoka release readiness
status: proposed
milestone: gate-0
depends_on: [G0-E01]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E10: Define Jidoka Release Readiness

## Goal

Approve the Jidoka compatibility, blocker, proof, and merge plan for Milestone 1.

## Scope

- Record separate Jidoka work for event order, controller cleanup, policy defaults, unsafe-effect recovery, and execution-adapter contracts.
- Give each Jidoka work item an owner, target release, proof artifact, dependency, and merge position in its external work system.
- Define the compatible immutable Jidoka source rule.
- Define the Jidoka release requirements for Jido Console.
- Assign dependency replacement to Milestone 1.
- Link Console parity and public-API boundary checks.

## Out of Scope

- Jidoka implementation changes
- A moving branch dependency
- Private Jidoka runtime or adapter internals in Console
- Milestone 1 dependency replacement

## Dependencies

This epic depends on G0-E01 for current Jidoka parity and build evidence.

## Pull Request Boundary

Deliver this epic in exactly one pull request in Jido Console. The five Jidoka changes stay in separately owned Jidoka work and pull requests. This pull request records and links the approved plan only.

## Acceptance Checks

- All five Jidoka blocker areas have separate linked work.
- Each linked item has an owner, release target, proof, dependency, and merge position.
- The compatibility rule rejects a local path, moving branch, or unspecified source for production.
- Console parity and public-boundary checks link to the exact Jidoka source identity.
- The plan states when Milestone 1 can replace the current dependency.

## Proof Artifacts

- Approved Jidoka blocker map
- Compatibility and release decision
- Merge-order graph
- Current parity and public-boundary results
- Milestone 1 dependency-replacement link

## Milestone Traceability

This epic covers the Jidoka work plan, compatibility requirements, release requirements, and blocker links in Gate 0.
