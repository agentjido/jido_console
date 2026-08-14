---
epic: G0-E03
type: epic
title: Freeze the golden coding task
status: proposed
milestone: gate-0
depends_on: [G0-E01, G0-E02]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E03: Freeze the Golden Coding Task

## Goal

Freeze one deterministic coding task that Milestone 1 must run through the production artifact.

## Scope

- Version the existing rate-limiter task as the canonical golden task.
- Record its exact initial repository state and expected final states.
- Cover discovery, read, search, edit, command, test, and exact diff operations.
- Cover approval, rejection, cancellation, and current-run revert paths.
- Reference immutable model-result and tool-result records from G0-E02.
- Record the golden-task decisions, accepted effects, and expected checks.
- Define the exact production-artifact invocation that Milestone 1 must use.
- Define a change-control rule for a new fixture version.

## Out of Scope

- Restricted-execution implementation
- A claim that the current product passes the Milestone 1 gate
- A new public example
- A second golden coding task

## Dependencies

This epic depends on G0-E01 for evidence identity and G0-E02 for recorded replay inputs.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request freezes the task, adds its verifier, and records the Milestone 1 invocation contract.

## Acceptance Checks

- The fixture has one versioned initial state and explicit expected states.
- The verifier checks every required operation and decision path.
- Verification does not need a live model call.
- The expected diff and current-run revert state are exact.
- A fixture change requires a new version or an approved correction record.
- The production-artifact command is stable and machine-readable.

## Proof Artifacts

- Golden task manifest and source digest
- Initial and expected repository states
- Referenced model-result and tool-result record identifiers
- Verifier results
- Milestone 1 production-artifact command

## Milestone Traceability

This epic covers the deterministic golden coding task that Gate 0 must freeze for Milestone 1.
