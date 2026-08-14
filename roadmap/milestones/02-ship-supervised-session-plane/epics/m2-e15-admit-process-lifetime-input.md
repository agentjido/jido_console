---
epic: M2-E15
type: epic
title: Admit Process-Lifetime Input Before Wake-Up
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e15
depends_on: [M2-E07, M2-E13]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E15: Admit Process-Lifetime Input Before Wake-Up

## Goal

Accept and identify input before sending an advisory or coalescing wake-up during one application lifetime.

## Scope

- Create a process-lifetime input identity before the wake-up message is sent.
- Store accepted input in the session owner before sending an advisory wake-up.
- Use coalescing wake-ups as an optimization, not as the input record.
- Deduplicate repeated wake-ups and repeated delivery attempts during the same application lifetime.
- Define accepted, started, completed, rejected, and cancelled input states.
- Test lost, repeated, delayed, and reordered wake-ups without losing or duplicating accepted input.
- State clearly that an application crash can lose accepted input before Milestone 3 durability.

## Out of Scope

- Restart-safe input admission
- Durable input receipts or a Console-to-Jidoka durable watermark
- Persistent queues or recovery after application restart
- Client delivery acknowledgements
- Remote input admission

## Dependencies

This epic depends on M2-E07 for process-lifetime input identity and on M2-E13 for the session owner that admits input.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds process-lifetime input admission, identity, wake-up handling, deduplication, and focused tests. It must not add persistent input storage or claim restart safety.

## Acceptance Checks

- Accepted input has an identity before any wake-up is sent.
- A lost or repeated wake-up does not lose or duplicate accepted input while the application stays alive.
- Wake-up coalescing cannot change accepted-input order.
- Input states and terminal reasons are explicit and testable.
- An application crash before Milestone 3 is documented as able to lose accepted input.
- No durable input receipt or restart-safe claim is present in this pull request.

## Proof Artifacts

- Process-lifetime input state machine
- Lost, repeated, delayed, and reordered wake-up results
- Input identity and deduplication results
- Application-crash limitation record

## Milestone Traceability

This epic implements the Milestone 2 process-lifetime admission rule while preserving Milestone 3 ownership of restart-safe input and durable recovery.
