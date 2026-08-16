---
epic: M2-E17
type: epic
title: Bound Client Delivery
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e17
depends_on: [M2-E07, M2-E13]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.1.0
---

# M2-E17: Bound Client Delivery

## Goal

Deliver session updates to each client with bounded memory and explicit acknowledgement behavior.

## Scope

- Give each attached client a bounded delivery state and pending-update limit.
- Define acknowledgement, safe coalescing, client stop, and delivery-timeout behavior.
- Keep delivery state separate for each client and separate from canonical session history.
- Coalesce only updates that the protocol marks safe to coalesce.
- Detect when a client falls behind and emit an explicit gap signal.
- Route every client-bound live message, including model and tool stream updates, through this delivery boundary.
- Ensure a slow or stopped client cannot cause unlimited growth in the receiving process mailbox or copied payload data.
- Prove the receiver bound from the receiving process. A finite sender-side pending list is not sufficient evidence.
- Keep client delivery process-lifetime only; do not add restart-safe receipts.

## Out of Scope

- Snapshot and gap recovery implementation
- Application-restart recovery
- Durable input or delivery receipts
- Remote client transport
- Multi-user authorization

## Dependencies

This epic depends on M2-E07 for process-lifetime client and acknowledgement identities and on M2-E13 for the session owner and client-projection boundary.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds bounded client delivery, acknowledgement, coalescing, lag detection, and focused tests. It must not implement durable delivery or restart recovery.

## Acceptance Checks

- Each client has a finite delivery bound and explicit lag behavior.
- Acknowledgements identify the client, session, and delivered sequence.
- Unsafe updates are never coalesced or dropped silently.
- Safe coalescing does not change the latest semantic state.
- Every client-bound live message uses the bounded delivery boundary.
- A slow or stopped client stays within the declared receiving mailbox and copied-payload bound, or the server emits one gap and stops delivery until recovery.
- Sender-side delivery metadata can stay bounded while the receiver does not read, without mailbox growth beyond the declared limit.
- A client that falls behind receives an explicit gap signal.
- Delivery state is not treated as durable input or restart-safe receipt state.

## Proof Artifacts

- Client delivery state machine
- Acknowledgement and coalescing contract
- Slow-client and stopped-client receiver-mailbox and payload-memory results
- Gap detection result
- Mailbox-growth limit evidence

## Milestone Traceability

This epic provides bounded client delivery for the Milestone 2 current-client contract and enables explicit gap recovery.
