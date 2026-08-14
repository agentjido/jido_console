---
epic: G0-E13
type: epic
title: Create the Milestone 1 delivery graph
status: proposed
milestone: gate-0
depends_on: [G0-E03, G0-E09, G0-E10, G0-E11]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E13: Create the Milestone 1 Delivery Graph

## Goal

Create and link the owned work graph that controls Milestone 1 delivery.

## Scope

- Create and link the Milestone 1 GitHub milestone.
- Create and link one or more Milestone 1 Beadwork epics.
- Link all Milestone 1 Beadwork tasks.
- Require an owner, effort class, dependency, readiness state, target release, and proof artifact for each task.
- Identify the Milestone 1 critical path and merge order.
- Add a stable repository manifest that stores the external identifiers.
- Define a read-only Beadwork export with a URI, revision, time, and digest.
- Define the maximum acceptable age for a Gate 0 export.
- Keep Beadwork as the source of truth for task fields and delivery state.

## Out of Scope

- Milestone 1 implementation
- A second task-status system in Markdown
- Completion claims for planned proof artifacts
- Gate 0 traceability code from G0-E14

## Dependencies

This epic depends on G0-E03, G0-E09, G0-E10, and G0-E11. The graph must include the golden proof target, product claim, Jidoka plan, Tilde boundary, and planned safety controls.

## Pull Request Boundary

Deliver this epic in exactly one pull request. External records can be created before the pull request. The pull request adds their stable links, identifier manifest, export contract, and critical-path reference.

## Acceptance Checks

- A reviewer can go from Milestone 1 to each linked epic and task.
- Every task has all six required delivery fields.
- Dependencies have no unknown item or cycle.
- The graph shows one clear critical path and merge order.
- Planned proof links have stable identifiers and named producers.
- Markdown does not copy mutable task status from Beadwork.
- The read-only export identifies its revision, time, and digest.
- The export URI and evidence contain no access token or credential.
- The export is audit evidence. It is not an editable local task system.

## Proof Artifacts

- GitHub milestone link and identifier
- Beadwork epic and task links
- Machine-readable delivery graph manifest
- Read-only Beadwork export reference, revision, and digest
- Critical-path reference
- Required-field audit

## Milestone Traceability

This epic covers the linked Milestone 1 milestone, Beadwork graph, task fields, and critical path in Gate 0.
