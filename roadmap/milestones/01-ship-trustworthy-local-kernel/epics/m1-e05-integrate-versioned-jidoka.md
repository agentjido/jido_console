---
epic: M1-E05
type: epic
title: Integrate the Approved Versioned Jidoka Release
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e05
depends_on: [M1-E01, M1-E04]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E05: Integrate the Approved Versioned Jidoka Release

## Goal

Use the approved Jidoka release through stable, documented facades in Jido Console.

## Scope

- Replace the pre-Milestone 1 Jidoka source with the approved immutable release or package.
- Pin the exact Jidoka source identity in project and release metadata.
- Update the Console adapter to use only the approved public policy and execution-adapter contracts.
- Preserve the Console public boundary and existing runtime behavior while integrating the new contracts.
- Run the compatibility, parity, and public-boundary checks required by Gate 0.
- Document the supported Jidoka version and known compatibility limits.

## Out of Scope

- Mutable branch dependencies or local path dependencies in production.
- Private Jidoka runtime or adapter internals in Console.
- New restricted policy behavior beyond the integrated contracts.
- Durable session recovery or remote execution.

## Dependencies

This epic depends on M1-E01 for the new application identity and M1-E04 for the landed additive Jidoka contracts.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request updates the pinned dependency, Console facades, compatibility checks, and release documentation. It must not add unrelated provider or packaging work.

## Acceptance Checks

- Production dependency resolution names one immutable approved Jidoka source.
- Production builds reject a local path, moving branch, or unspecified Jidoka source.
- Console source uses only documented Jidoka client, policy, and execution-adapter facades.
- The Jidoka compatibility contract passes against the pinned release.
- Current parity and public-boundary checks pass against the pinned release.
- Release metadata records the exact Jidoka version and source identity.

## Proof Artifacts

- Dependency lock and immutable source record.
- Jidoka compatibility contract result.
- Console parity result.
- Public API boundary scan result.
- Release metadata showing the approved Jidoka identity.

## Milestone Traceability

This epic covers the Milestone 1 work to use an approved versioned Jidoka release or package and to pass its compatibility contract without following a mutable branch.
