---
epic: M3-E25
type: epic
title: Add Explicit Retry
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e25
depends_on: [M3-E15, M3-E22, M3-E23, M3-E24]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E25: Add Explicit Retry

## Goal

Create new work from a failed, uncertain, or transcript-only boundary without reusing old execution authority.

## Scope

- Define the renderer-neutral Session.Client retry request and result contract
  before any client adapter uses it.

- Add a typed retry operation with a required idempotency key and source boundary.
- Create a new request, receipt, result identity, effect reservation namespace, and generation-bound operation.
- State whether the retry can call a model, tool, or both before execution.
- Require the recorded safety, consent, permission, workspace, model, and credential checks.
- Link the new request to the failed or uncertain source without changing the old record.
- Reject automatic retry, identity reuse, stale authority, and ambiguous unsafe effects.
- Make exact repeated retry requests return the same new request.

## Out of Scope

- Automatic backoff or provider retry policy
- Repairing the source record
- Forking a session
- Client or TUI integration
- Remote job retry

## Dependencies

This epic depends on M3-E15, M3-E22, M3-E23, M3-E24. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E15 provides the effect safety and uncertainty policy.
- M3-E22 and M3-E23 define the exact and transcript-only source states.
- M3-E24 defines repaired and abandoned state rules.
- M3-E11 provides restart-safe request admission.

### Decisions and invariants

- A retry is a new request, not replay of the old receipt.
- The old event, effect, result, approval, and generation identities never become current in the retry.
- Unsafe or ambiguous work needs explicit reconciliation or consent before retry.
- The result states in advance whether execution can call a model or tool.
- Retry admission commits before any wake-up.

### Delivery steps

1. Add retry request, source, policy, and result schemas.
2. Validate source state, safety, consent, model, workspace, and credential references.
3. Allocate and commit the new receipt, request, and identity set.
4. Link retry provenance to the unchanged source record.
5. Route permitted retry through normal durable admission and effect reservation.
6. Add exact-repeat, conflict, unsafe, stale, abandoned, and crash tests.
7. Record the operation safety matrix.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Exact repeat | Same retry key returns same new request | No second receipt |
| Unsafe source | Consent or reconciliation required | No external call before approval |
| Transcript source | New request has no inherited live authority | Explicit model/tool policy |
| Old identity reuse | Rejected | Source records unchanged |
| Crash after admission | Recovered request wakes once | New generation and operation identity |

### Completion boundary and handoff

M3-E31 and M3-E32 expose retry through supported clients. M3-E33 proves that all clients observe the same new request and outcomes.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- Retry always creates or returns one new request identity.
- It never reuses an old receipt, result, approval, effect reservation, lease, or generation.
- The result states whether a model or tool call is permitted.
- Unsafe or ambiguous work cannot retry without the required explicit decision.
- Retry admission is durable before wake-up.
- The source history stays unchanged and gains a bounded provenance link.
- Repeated retry is idempotent and a conflicting payload fails.
- Crash recovery runs the new request at most once.

## Proof Artifacts

- Retry schema and safety matrix
- New-identity and provenance result
- Unsafe-consent denial fixtures
- Exact-repeat and conflict result
- Retry crash-recovery trace

## Milestone Traceability

This epic defines retry as a distinct safe operation instead of a hidden form of resume or replay.
