---
epic: M2-E01
type: epic
title: Land the Ordered Jidoka Async Event Contract
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e01
depends_on: []
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.8
---

# M2-E01: Land the Ordered Jidoka Async Event Contract

## Goal

Make one Jidoka request emit one valid ordered event stream.

## Scope

- Deliver one external Jidoka pull request for the async event contract.
- Define one sequence owner for each request.
- Emit contiguous per-request event order.
- Emit one terminal event for each request.
- Define race behavior for completion, cancellation, timeout, and owner exit.
- Reject or classify an event that cannot be assigned to the request sequence.
- Add deterministic tests for event races and terminal-event rules.

## Out of Scope

- Jido Console protocol or event projection.
- Console session ownership.
- Request-controller cleanup from M2-E02.
- Durable event storage or restart-safe input.

## Dependencies

This epic starts from the approved Milestone 1 source and Jidoka dependency
baseline on `main`. Deferred public v0.1 publication in M1-E30 does not block
this work.

## Pull Request Boundary

Deliver this epic in exactly one external Jidoka pull request. The pull request contains the one-sequence-owner contract, event ordering, terminal-event behavior, race handling, and tests. It must not contain Jido Console integration.

## Acceptance Checks

- Each request has one sequence owner.
- Events for one request have contiguous, deterministic order.
- Each request has exactly one terminal event.
- Completion, cancellation, timeout, and owner-exit races produce one valid terminal result.
- A late or duplicate event cannot create a second terminal result.
- The contract result is deterministic without a live provider.

## Proof Artifacts

- External Jidoka pull request link.
- Ordered event contract and sequence-owner record.
- Race test results.
- Terminal-event uniqueness result.
- Immutable source and release identity.

## Milestone Traceability

This epic covers the Milestone 2 requirement to land the additive Jidoka fix for one ordered async event stream before Console integration.
