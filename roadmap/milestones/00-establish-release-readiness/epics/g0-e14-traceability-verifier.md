---
epic: G0-E14
type: epic
title: Enforce delivery traceability
status: proposed
milestone: gate-0
beadwork_id: jido_console-g0e14
depends_on: [G0-E13]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.5
---

# G0-E14: Enforce Delivery Traceability

## Goal

Reject a Milestone 1 delivery graph that has missing, stale, or broken required data.

## Scope

- Validate the roadmap milestone, GitHub milestone, Beadwork epic, and Beadwork task relations.
- Validate owner, effort class, dependency, readiness state, target release, and proof artifact fields.
- Detect unknown identifiers, duplicate identifiers, dependency cycles, and an invalid critical path.
- Read the declared read-only Beadwork export and verify its revision, time, digest, and freshness limit.
- Check stable repository identifiers without copying mutable task state into Markdown.
- Use local positive and negative fixtures in normal tests.
- Add the check to the required repository quality path.
- Give an actionable message for each failure.

## Out of Scope

- Creation of the delivery graph from G0-E13
- Beadwork task updates
- An editable local copy of Beadwork task state
- Milestone 1 implementation
- A general project-management system

## Dependencies

This epic depends on G0-E13 for the delivery graph and its stable manifest.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the verifier, fixtures, tests, and quality-gate integration.

## Acceptance Checks

- The complete Milestone 1 graph passes the verifier.
- Removal of each required field produces a focused failure.
- Broken, unknown, duplicate, and cyclic relations fail.
- An invalid critical path fails.
- An invalid export revision, digest, or freshness value fails.
- Normal tests use controlled local fixtures and make no service call.
- The Gate 0 audit validates the declared read-only Beadwork export.
- The result identifies the exact record that needs correction.

## Proof Artifacts

- Traceability schema
- Positive graph fixture and result
- Negative fixture results for each failure class
- Real-export validation contract
- Quality-gate integration result

## Milestone Traceability

This epic covers the automated broken-traceability check in Gate 0 and supplies the traceability result for its exit gate.
