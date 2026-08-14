---
epic: M2-E13
type: epic
title: Make the Session Server the Runtime Owner
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e13
depends_on: [M2-E07, M2-E11, M2-E12]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E13: Make the Session Server the Runtime Owner

## Goal

Make one supervised session server the only owner of live history, runs, queues, controls, and event order.

## Scope

- Store one semantic session state and its active-run state in the session server.
- Make the server the sole authority for event order, accepted input, control state, and live session identity.
- Route commands, interactions, approvals, steering, follow-up input, and worker results through the server.
- Validate actions, turns, lanes, requests, approvals, controls, clients, and results against the identity types from M2-E07.
- Publish ordered semantic updates to the client-delivery boundary without retaining renderer state.
- Reject stale, repeated, or cross-session results before they change state.
- Define the delegation boundary that keeps model and tool work outside the server process.

## Out of Scope

- Client delivery backpressure and gap recovery
- Application-restart recovery
- Durable input receipts or a Console-to-Jidoka watermark
- Multi-agent ownership and worktree lanes
- Remote client authorization
- Model and tool worker implementation from M2-E14

## Dependencies

This epic depends on M2-E07 for process-lifetime identities, M2-E11 for semantic reduction and replay, and M2-E12 for the supervised session topology.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request moves live session ownership into the supervised session server and uses the existing identity contracts in lifecycle tests. It must not redefine identity types, implement model or tool workers, add restart-safe persistence, or add a new client transport.

## Acceptance Checks

- One session server is the only owner of live history, active runs, queues, controls, and event order.
- Attached clients cannot create a second owner or mutate shared state directly.
- Stale, repeated, and cross-session worker results are rejected.
- Event order remains monotonic and follows the reducer contract.
- A client can detach while the session remains alive and can attach again during the same application lifetime.
- Client exit and session-server failure have explicit isolation and cleanup results.

## Proof Artifacts

- Session ownership and identity matrix
- Live event-order result
- Stale and cross-session result denial results
- Detach and reattach result during one application lifetime
- Client-exit and owner-failure isolation report

## Milestone Traceability

This epic implements the canonical supervised session owner required by the Milestone 2 outcome.
