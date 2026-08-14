---
epic: M2-E05
type: epic
title: Land the Portable Jidoka Projection Contract
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e05
depends_on: [M2-E01, M2-E02, M2-E03]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E05: Land the Portable Jidoka Projection Contract

## Goal

Expose one portable Jidoka projection contract for Console integration.

## Scope

- Deliver one external Jidoka pull request for the projection contract.
- Add one documented root facade for the projection boundary.
- Return portable, redacted, bounded projection data.
- Preserve stable runtime and request identities needed by Console.
- Define projection behavior for known events, unknown bounded data, errors, and terminal results.
- Keep private Jidoka runtime structures outside the projection.
- Add deterministic projection fixtures and compatibility tests.

## Out of Scope

- Jido Console event classification.
- Console session state reduction.
- Direct use of Jidoka private runtime modules.
- Durable checkpoints or restart recovery.

## Dependencies

This epic depends on M2-E01 for the ordered Jidoka event stream, M2-E02 for completed-request cleanup and handle semantics, and M2-E03 for the canonical Console protocol shapes.

## Pull Request Boundary

Deliver this epic in exactly one external Jidoka pull request. The pull request contains the root facade, portable projection types, redaction, bounds, and tests. It must not contain Jido Console integration or private-runtime exposure.

## Acceptance Checks

- Console can consume projection data through one documented root facade.
- Projection records preserve the stable request, turn, and event identities required by the protocol.
- Projection output is portable and JSON-compatible.
- Sensitive content is redacted according to its declared sensitivity.
- Projection size and unknown-data bounds are enforced.
- Private Jidoka runtime structures, PIDs, references, and functions do not cross the facade.
- Known, unknown, error, and terminal projection fixtures pass deterministic tests.

## Proof Artifacts

- External Jidoka pull request link.
- Root-facade API record.
- Portable projection schema and identity map.
- Redaction and bounded-size results.
- Private-runtime boundary scan.

## Milestone Traceability

This epic covers the Milestone 2 requirement to project canonical Jidoka events at one boundary and preserve their runtime identities without exposing runtime internals.
