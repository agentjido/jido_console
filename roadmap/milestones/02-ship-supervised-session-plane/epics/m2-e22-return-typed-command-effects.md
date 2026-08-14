---
epic: M2-E22
type: epic
title: Return Typed Command Effects
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e22
depends_on: [M2-E11, M2-E21]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E22: Return Typed Command Effects

## Goal

Return command meaning as typed effects and keep it separate from each client's
presentation outcome.

## Scope

- Define the typed effect result for a semantic command.
- Represent accepted, rejected, deferred, failed, and no-effect command
  outcomes with explicit types.
- Keep command meaning independent of TUI, automation, text, and JSON rendering.
- Bind effects to the command identity, session, run, request, and provenance.
- Preserve bounded unknown effect data without granting authority.
- Return a stable effect envelope that clients can render or transform.
- Keep permission requirements available to the permission life cycle.

## Out of Scope

- The command and client declaration registry owned by M2-E21.
- Permission request, response, expiry, and cancellation transitions owned by
  M2-E24.
- Model content and structured view details owned by M2-E23.
- Client adapter migration.

## Dependencies

This epic depends on M2-E11 for semantic reduction and outcome behavior
and M2-E21 for the single command and client registry.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds typed
command effects, effect validation, provenance binding, and deterministic
effect tests. It must not add renderer adapters, model-content formatting, or
the permission state machine.

## Acceptance Checks

- Every command result has a typed effect or an explicit no-effect result.
- Accepted, rejected, deferred, and failed effects are distinct and stable.
- Effect meaning is identical across client surfaces.
- An effect is bound to its command, session, run, request, and provenance.
- Unknown bounded effect data cannot grant authority.
- Permission requirements remain available without embedding client rendering.
- Deterministic tests cover each effect outcome and invalid effect data.

## Proof Artifacts

- Typed command-effect schema
- Effect outcome and validation table
- Provenance-bound effect examples
- Unknown-data safety results
- Cross-surface effect equivalence tests

## Milestone Traceability

This epic covers the Milestone 2 requirement to return typed command effects
and to separate command meaning from client outcomes.
