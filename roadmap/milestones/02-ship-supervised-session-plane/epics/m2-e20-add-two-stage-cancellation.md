---
epic: M2-E20
type: epic
title: Add Two-Stage Cancellation
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e20
depends_on: [M2-E14, M2-E19]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E20: Add Two-Stage Cancellation

## Goal

Provide graceful cancellation first and force kill only when the exact owned
worker tree does not drain.

## Scope

- Send one graceful cancellation request bound to the exact session, run,
  request, and worker identities.
- Report the requested and saving states before cancellation completes.
- Record the cancelled result only after the exact worker drain is complete.
- Start force kill only when the graceful cancellation cannot complete the
  required drain.
- Force kill the complete owned worker tree, including descendants.
- Report cancellation, force kill, and failed cleanup as separate outcomes.
- Keep cancellation idempotent for repeated requests for the same work.

## Out of Scope

- The worker registry and exact drain state owned by M2-E19.
- Client delivery, acknowledgement, or snapshot recovery.
- Application-restart recovery.
- Remote process control.

## Dependencies

This epic depends on M2-E14 for supervised worker ownership and M2-E19 for
exact worker drain and failed-drain results.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds graceful
cancel, saving and cancelled states, force-kill escalation, complete-tree
cleanup, and deterministic cancellation tests. It must not redefine worker
drain identity or add client adapter behavior.

## Acceptance Checks

- A cancellation request is bound to the exact session, run, request, and
  worker identities.
- Graceful cancellation reports requested and saving before it reports
  cancelled.
- A cancelled result is not emitted before the exact worker tree drains.
- Force kill starts only after graceful cancellation cannot complete the drain.
- Force kill stops every owned descendant or returns a failed-cleanup result.
- Repeated cancellation requests do not create duplicate cancellation work.
- A stale, repeated, or cross-session cancellation cannot affect current work.
- Deterministic tests cover graceful completion, force-kill escalation, failed
  cleanup, and repeated cancellation.

## Proof Artifacts

- Two-stage cancellation state machine
- Graceful cancellation and saving records
- Force-kill and complete-tree cleanup records
- Failed-cleanup evidence
- Repeated and cross-session cancellation rejection results

## Milestone Traceability

This epic covers the Milestone 2 requirement for graceful cancel, force kill,
and exact worker-drain contracts. It provides evidence that cancellation does
not corrupt the supervised session or leave an owned worker tree running.
