---
epic: M3-E09
type: epic
title: Add Durable Session Generation Fencing
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e09
depends_on: [M3-E08]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E09: Add Durable Session Generation Fencing

## Goal

Prevent every earlier session-owner incarnation from changing recovered state.

## Scope

- Atomically claim a larger durable generation and a unique owner-instance identity.
- Add generation to session owners, requests, workers, runtime events, timers, permissions, storage operations, recovery work, clients, and forks.
- Reject stale storage writes before mutation with a generation compare-and-set.
- Reject stale worker results, timers, callbacks, replies, and client operations before semantic reduction.
- Keep Console generation separate from Jidoka lease and bind both at watermark points.
- Record generation transitions in the immutable audit chain.

## Out of Scope

- Full recovery orchestration
- Canonical event persistence
- Exact resume
- Jidoka lease implementation
- Client restart attachment

## Dependencies

This epic depends on M3-E08. This dependency supplies the only bounded, quota-controlled write path required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E08 supplies the only quota-controlled store path and operation-ID lookup.
- M2 integrity identities and client attachment identities are frozen.

### Decisions and invariants

- The durable fence is session ID, generation, owner-instance ID, and operation ID.
- Every owner start, including same-application process recovery, claims a new generation before it becomes ready.
- Storage enforces the fence. Ignoring a stale reply in the session process is not sufficient.
- An old attachment never upgrades to a new generation. Restart attach creates a new attachment.
- Generation overflow or conflict makes the session unavailable; it never resets to one.

### Delivery steps

1. Add generation claim, release, inspect, and conflict operations.
2. Extend identity values and internal messages with generation and owner instance.
3. Add storage-side conditional checks to every mutating operation.
4. Fence workers, runtime events, timers, permissions, callbacks, and client commands.
5. Add exact stale-generation error and audit values.
6. Add process-crash, delayed-message, cross-session, concurrent-claim, and overflow tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Concurrent claim | Only one owner gets the next generation | Other claim is typed conflict |
| Old storage request | Compare-and-set rejects before mutation | Durable head unchanged |
| Delayed worker or timer | Session owner rejects it | No event or state change |
| Old client | Input, control, permission, delivery, and detach fail | Current attachment unchanged |
| Jidoka lease | Generation and lease are both checked at link points | Neither identity substitutes for the other |

### Completion boundary and handoff

M3-E10 persists semantic history under the fence. M3-E21 uses generation claim as a mandatory recovery phase.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- Each session-owner incarnation has one larger durable generation and unique owner instance.
- Every mutating store operation checks the exact generation before mutation.
- Old worker, runtime, timer, permission, storage, recovery, client, and fork data cannot change current state.
- Concurrent generation claims have one winner.
- Old client handles and delivery tokens remain invalid after restart.
- Console generation and Jidoka lease identities remain distinct and are both available for later watermark validation.
- Generation transitions are immutable and auditable.
- No full startup recovery or exact resume is implemented.

## Proof Artifacts

- Generation schema and state machine
- Concurrent claim result
- Stale storage-write matrix
- Delayed worker, timer, reply, and client results
- Generation-to-Jidoka-lease identity record

## Milestone Traceability

This epic provides the durable fencing rule in the Milestone 3 exit gate.
