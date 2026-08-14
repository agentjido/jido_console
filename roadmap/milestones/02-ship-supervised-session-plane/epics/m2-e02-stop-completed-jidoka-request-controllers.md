---
epic: M2-E02
type: epic
title: Stop Completed Jidoka Request Controllers
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e02
depends_on: [M2-E01]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E02: Stop Completed Jidoka Request Controllers

## Goal

Stop completed Jidoka request controllers and expose safe handle semantics.

## Scope

- Deliver one external Jidoka pull request for chat and session-sequence request-controller cleanup.
- Define when a request and its session-sequence controller are complete.
- Stop controllers after normal completion, error, cancellation, timeout, and owner exit.
- Define handle state after completion and after cleanup.
- Reject operations against a completed or cleaned-up handle with a stable result.
- Add deterministic controller-leak and handle-semantics tests.

## Out of Scope

- Jido Console integration.
- Console session-server supervision.
- Durable session recovery.
- Remote request controllers.

## Dependencies

This epic depends on M2-E01 for the ordered async event contract and terminal-event behavior.

## Pull Request Boundary

Deliver this epic in exactly one external Jidoka pull request. The pull request owns cleanup and handle semantics for both controller classes. If that work cannot fit in one reviewable pull request, split this epic in a roadmap change before implementation starts. It must not contain Console integration.

## Acceptance Checks

- Normal async completion leaves no request controller.
- Error, cancellation, timeout, and owner exit leave no request controller.
- Session-sequence controllers stop after the sequence reaches its terminal state.
- Completed handles return the documented result and do not restart work.
- A cleanup race cannot create a duplicate terminal event or live controller.
- Controller cleanup and handle semantics pass deterministic tests.

## Proof Artifacts

- External Jidoka pull request link.
- Chat and session-sequence controller ownership record.
- Controller cleanup results for all termination paths.
- Completed-handle behavior results.
- No-live-controller inspection result.

## Milestone Traceability

This epic covers the Milestone 2 requirement to land Jidoka request-controller cleanup and handle semantics before Console integration. Normal completion owns the explicit milestone exit check. The other terminal paths supply the complete cleanup contract and common release-gate evidence without changing the milestone exit gate.
