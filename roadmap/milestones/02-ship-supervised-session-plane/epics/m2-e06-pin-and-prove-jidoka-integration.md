---
epic: M2-E06
type: epic
title: Pin and Prove the Milestone 2 Jidoka Integration
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e06
depends_on: [M2-E02, M2-E05]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E06: Pin and Prove the Milestone 2 Jidoka Integration

## Goal

Pin the approved Jidoka release and prove that Console uses only the approved integration contracts.

## Scope

- Update the Console dependency to one immutable approved Jidoka source.
- Record the exact source identity in the lock and release evidence.
- Integrate the ordered event and controller-cleanup contracts through documented facades.
- Integrate the portable projection contract through its documented root facade.
- Run Jidoka compatibility, parity, and public-boundary checks.
- Reject local paths, moving branches, and unspecified sources in production builds.

## Out of Scope

- New Jidoka implementation changes.
- Console session-server or client behavior.
- Private Jidoka runtime or adapter access.
- Durable session recovery.

## Dependencies

This epic depends on M2-E02 for controller cleanup and M2-E05 for the portable projection contract.

## Pull Request Boundary

Deliver this epic in exactly one Jido Console pull request. The pull request changes only the pinned Jidoka source, documented Console facades, compatibility checks, and integration evidence.

## Acceptance Checks

- Production dependency resolution names one immutable Jidoka source.
- A production build rejects a local path, moving branch, or unspecified Jidoka source.
- Console source uses the ordered event and projection contracts through documented facades.
- Compatibility tests pass for ordered events, controller cleanup, handles, and projection data.
- The public-boundary scan finds no private Jidoka runtime use.
- Release evidence records the exact Jidoka source identity.

## Proof Artifacts

- Dependency lock and immutable source record.
- Jidoka compatibility results.
- Console parity results.
- Public-boundary scan result.
- Release integration record.

## Milestone Traceability

This epic covers the Milestone 2 requirement to complete the approved Jidoka integration in Console before the supervised session owner uses it.
