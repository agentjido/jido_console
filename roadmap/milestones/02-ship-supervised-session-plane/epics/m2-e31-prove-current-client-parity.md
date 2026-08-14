---
epic: M2-E31
type: epic
title: Prove Current-Client Parity
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e31
depends_on: [M2-E27, M2-E28, M2-E29, M2-E30]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E31: Prove Current-Client Parity

## Goal

Prove that every current client observes the same session behavior.

## Scope

- Run one contract suite against the TUI, automation, text, and JSON clients.
- Compare ordered outcomes, capability behavior, errors, cancellation, and gap recovery.
- Prove automation backward compatibility for schemas, artifacts, output, and exit statuses.
- Record parity evidence from deterministic provider-free fixtures.

## Out of Scope

- New client surfaces.
- Feature work for a client that does not affect parity.
- Removal of the old TUI-owned session path.
- A production release candidate.

## Dependencies

This epic depends on M2-E27, M2-E28, M2-E29, and M2-E30 because every current client must use `Session.Client` before parity can be proved.

## Pull Request Boundary

Deliver this epic in exactly one proof-only pull request. The pull request adds the shared parity suite and evidence. A behavior defect must return to its owning client epic, or receive a new roadmap epic, before this proof can pass.

## Acceptance Checks

- One contract suite runs each current client against the same deterministic fixtures.
- Each client observes the same ordered outcomes and capability results.
- Client-specific rendering does not change session state or semantic outcomes.
- Automation schemas, artifacts, standard output, and exit statuses remain backward-compatible.
- Duplicate, stale, cross-session, and gap cases fail or recover as the shared contract specifies.

## Proof Artifacts

- Current-client parity report.
- Shared contract fixture corpus.
- Automation compatibility result.
- Ordered-outcome comparison.

## Milestone Traceability

This epic covers the Milestone 2 proof that all current clients have parity through `Session.Client`.
