---
epic: M3-E11
type: epic
title: Admit Restart-Safe Input and Commands
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e11
depends_on: [M3-E10]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E11: Admit Restart-Safe Input and Commands

## Goal

Accept each mutating input or command exactly once before any execution wake-up.

## Scope

- Require a caller idempotency key for durable input and mutating commands.
- Normalize each operation and calculate a payload digest before persistence.
- Reject credential-value fields, credential-bearing structures, inline
  authorization data, URI user data, query credentials, interpolation, and
  shell credential arguments before receipt creation. Do not resolve an
  external credential source or compare ordinary input with its value.
- Atomically commit the receipt, admission record, canonical event, and session sequence.
- Return the existing receipt for an exact retry and a conflict for the same key with different data.
- Send only an advisory wake-up after durable commit.
- Recover committed accepted work that did not start before a crash.
- Add receipt status lookup for commit-unknown timeouts.

## Out of Scope

- Read-only status and capability operations
- Durable queue contents and permission state
- Effect reservation
- Jidoka watermark verification
- Client output acknowledgement

## Dependencies

This epic depends on M3-E10. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E10 supplies durable canonical event append and exact replay.
- M2 send, steer, queue, remove, and invoke operations remain separate.
- The M3-E07 writer can resolve an operation ID after timeout.

### Decisions and invariants

- The uniqueness key is session, operation kind, principal, and idempotency key.
- The payload digest covers normalized input, target identity, queue kind, principal, schema, and attachment references.
- Durable acceptance means the receipt and admission event committed. It does not mean execution started or completed.
- Wake-up is advisory. Recovery finds accepted unstarted work even if the wake-up was lost.
- Read-only operations do not create durable receipts.
- A structural sensitive-value rejection returns a redacted typed result. It
  creates no receipt, event, sequence, Jidoka value, or wake-up.

### Delivery steps

1. Add durable input and command receipt values and API results.
2. Add normalized digest, uniqueness, and pre-persistence structural credential-bearing validation.
3. Add the atomic receipt plus event storage operation.
4. Move wake-up after the successful committed receipt.
5. Add receipt lookup and commit-unknown retry behavior.
6. Add recovery query for accepted, started, and terminal receipt states.
7. Add crash injection before commit, after commit, before wake, and after wake.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Exact retry | Same key and digest returns same receipt | No second event or wake authority |
| Conflict | Same key and different digest fails | Original receipt unchanged |
| Crash before commit | No receipt and no wake | Retry can use same key |
| Crash after commit | Receipt returns after restart | Accepted work wakes once |
| Timeout unknown | Lookup by operation ID resolves state | No new operation identity |
| Credential-bearing input | Typed redacted structural rejection before receipt | Zero durable bytes and no wake-up |

### Completion boundary and handoff

M3-E12 persists the queue and interaction state created by these operations. M3-E14 records the exact turn identity before work starts.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- Input and mutating commands require one bounded idempotency key.
- The receipt and canonical admission event commit atomically.
- No wake-up occurs before durable acceptance.
- The same key and payload return the exact existing receipt.
- The same key with different data fails without state change.
- A crash after commit but before wake-up does not lose accepted work.
- A repeated request cannot create a second receipt, event, sequence, permission, or projection change.
- A prompt, command, argument, or metadata value that fails the structural
  credential-bearing policy creates no receipt, event, sequence, Jidoka value,
  log value, or wake-up.
- Client delivery acknowledgement remains explicitly process-local.

## Proof Artifacts

- Durable receipt schema
- Idempotency and conflict fixtures
- Atomic admission transaction result
- Wake-after-commit trace
- Admission crash matrix
- Receipt lookup and unknown-commit result

## Milestone Traceability

This epic implements the Milestone 3 restart-safe admission rule.
