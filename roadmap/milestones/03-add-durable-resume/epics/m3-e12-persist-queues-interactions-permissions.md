---
epic: M3-E12
type: epic
title: Persist Queues, Interactions, and Permissions
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e12
depends_on: [M3-E11]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E12: Persist Queues, Interactions, and Permissions

## Goal

Restore exact steering, follow-up, interaction, permission, control, and cancellation state after restart.

## Scope

- Persist steering and follow-up queue additions, order, removal, consumption, and terminal state.
- Persist pending interactions and their exact request and response identities.
- Persist permission request, principal, scope, effect, expiry, response, cancellation, and consumption state.
- Persist cancellation request and terminal result without reviving cancelled authority.
- Make every mutation idempotent and generation-fenced.
- Rebuild the M2 queue, permission, and control projections from authoritative records.
- Record expiry decisions with an injected durable clock value.

## Out of Scope

- Effect execution or result persistence
- Exact resume orchestration
- Client rendering
- Remote or multi-user authority
- Automatic approval after restart

## Dependencies

This epic depends on M3-E11. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E11 supplies durable operation receipts and ordered canonical events.
- M2 queue, permission, cancellation, and typed-effect contracts are frozen.
- M3-E09 generation fencing applies to all mutations.

### Decisions and invariants

- Queue order is durable data. A recovered owner does not recalculate it from arrival time.
- A pending permission restores as pending only when identity, scope, expiry, and Jidoka review state later agree.
- An expired, cancelled, rejected, consumed, stale-generation, or abandoned permission never becomes current authority.
- Queue consumption commits before execution wake-up so recovery cannot consume one item twice.
- Clock input is explicit and recorded; system time alone is not a replay oracle.

### Delivery steps

1. Add queue mutation and position records.
2. Add interaction and permission lifecycle records.
3. Add cancellation and control lifecycle records.
4. Integrate idempotent mutations with Session.Client operations.
5. Add projection rebuild for queues, interactions, permissions, and controls.
6. Add injected-clock expiry and stale-generation checks.
7. Add crash tests around add, remove, consume, decide, expire, and cancel commits.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Queue order | Restart restores exact order and identities | No duplicate consumption |
| Permission pending | Identity, scope, principal, and expiry restore | No automatic decision |
| Permission terminal | Expired, cancelled, rejected, or consumed stays terminal | Cannot grant authority |
| Cancellation | One terminal cancellation result | No revived worker authority |
| Crash | Mutation is old or new, never partial | Receipt and event agree |

### Completion boundary and handoff

M3-E14 uses the restored queue and permission identities in durable turn manifests. M3-E15 binds effect reservations to exact permission records.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- Steering and follow-up queues restore exact order and identities.
- Add, remove, consume, approve, reject, expire, cancel, and control operations are idempotent.
- Pending interactions and permissions restore only with their complete authority data.
- Expired, cancelled, rejected, consumed, and old-generation authority cannot return.
- Queue consumption and execution wake-up cannot cause duplicate work.
- Rebuilt projections equal the pre-restart semantic state.
- Every crash point produces one old or new valid state.
- No model, tool, or automatic approval runs during restore.

## Proof Artifacts

- Queue record and ordering schema
- Interaction and permission lifecycle matrix
- Cancellation recovery results
- Projection rebuild equivalence
- Expiry and stale-authority fixtures
- Mutation crash traces

## Milestone Traceability

This epic preserves the live control state required by the exact-resume exit gate.
