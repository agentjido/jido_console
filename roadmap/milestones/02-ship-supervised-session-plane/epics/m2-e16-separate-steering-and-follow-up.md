---
epic: M2-E16
type: epic
title: Separate Steering from Follow-Up Input
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e16
depends_on: [M2-E13, M2-E15]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E16: Separate Steering from Follow-Up Input

## Goal

Keep active-run steering and next-run follow-up input in separate queues with clear operations.

## Scope

- Define distinct queue types for active-run steering and queued follow-up input.
- Add operations to show, add, remove, and consume each queue independently.
- Bind each queue item to the session, run, client, input, and process-lifetime identity.
- Preserve deterministic order within each queue.
- Prevent steering from becoming an accidental next-run prompt.
- Prevent follow-up input from changing the active run unless an explicit control accepts it.
- Project queue state and terminal outcomes through the semantic protocol.

## Out of Scope

- Restart-safe queue persistence
- Durable input receipts
- Multi-agent lanes or shared worktree queues
- Client delivery backpressure
- A new model or tool execution policy

## Dependencies

This epic depends on M2-E13 for the session owner and queue authority and M2-E15 for process-lifetime input identity and admission.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the two queue models, operations, identity checks, and focused tests. It must not add persistent queue recovery or a second session owner.

## Acceptance Checks

- Steering and follow-up input use separate queues and separate operations.
- Show, add, remove, and consume operations cannot cross queue boundaries.
- Queue items retain session, run, client, and input identity.
- Queue order is deterministic during one application lifetime.
- Steering cannot become a follow-up prompt without an explicit operation.
- Follow-up input cannot mutate an active run without an explicit control.

## Proof Artifacts

- Steering and follow-up queue schema
- Queue operation and identity matrix
- Cross-queue denial results
- Ordering and lifecycle results
- Semantic projection examples

## Milestone Traceability

This epic implements the distinct active-run and next-run input paths required by the Milestone 2 session owner.
