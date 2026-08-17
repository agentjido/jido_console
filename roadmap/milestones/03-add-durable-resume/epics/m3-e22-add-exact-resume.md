---
epic: M3-E22
type: epic
title: Add Exact Resume
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e22
depends_on: [M3-E21]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E22: Add Exact Resume

## Goal

Restore one session at the verified Console-to-Jidoka boundary and continue only through an explicit, safe operation.

## Scope

- Validate the exact-resume preconditions from Console history, watermark, Jidoka state, generation, turn manifest, workspace, queues, permissions, and effects.
- Restore the Jidoka session value and execution-environment checkpoint through public contracts.
- Restore semantic state, accepted unstarted work, queues, pending permission, turn identity, and context projection.
- Start one generation-fenced Session.Server from the complete exact candidate.
- Return `ready_exact` without calling a model or tool.
- Add a separate exact-continuation operation that acquires current authority before execution.
- Block continuation for uncertainty, drift, missing or changed credential-profile identity, unavailable selected reference, incompatible schema, stale authority, or invalid checkpoint.
- Prove state equivalence before and after application restart.

## Out of Scope

- Transcript-only behavior or fallback
- Retry, repair, abandon, or fork
- Client restart attachment
- Renderer changes
- Automatic unsafe-effect resolution

## Dependencies

This epic depends on M3-E21. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E21 returns a complete generation-fenced `exact_candidate` plan and has
  not started Session.Server or woken work.
- The verified watermark, Jidoka value, turn manifest, and authoritative Console history all validate.
- The current execution environment can restore the recorded checkpoint.

### Decisions and invariants

- Exact restore does not call a provider or tool.
- Exact continuation is a new explicit operation after `ready_exact`; attach alone never wakes it.
- Exact mode never falls back silently to transcript-only mode.
- An uncertain unsafe effect, missing identity, or workspace drift blocks continuation.
- Accepted unstarted input after the watermark remains durable and wakes only under the recovered owner policy.
- The durable input receipt is the prior explicit request. After `ready_exact`,
  the new owner wakes that accepted unstarted work once. A new continuation
  still requires a new explicit request.

### Delivery steps

1. Add the exact-resume precondition validator.
2. Restore Jidoka, execution-environment, Console, queue, permission, turn, and context state.
3. Start one generation-fenced Session.Server and add the `ready_exact` result and stable limitation data.
4. Wake previously accepted unstarted work once, then add explicit new exact continuation with current generation and authority checks.
5. Add provider-free equivalence fixtures for active, waiting, hibernated, completed, failed, and cancelled sessions.
6. Add missing checkpoint, drift, secret-reference, uncertainty, and schema denial tests.
7. Add process and application restart integration tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Exact restore | Recovered state equals the durable oracle | Verified watermark and current generation |
| No execution on load | Provider and tool probes stay at zero calls | Attach and restore only |
| Continuation | Runs only after explicit current request | New lease and generation checks |
| Unsafe uncertainty | Continuation is blocked | No external call |
| Workspace or credential gap | Typed failure lists valid choices | No mode change |

### Completion boundary and handoff

M3-E28 exposes exact readiness through Session.Client. M3-E25 uses the explicit new-request boundary for retry. M3-E26 uses verified safe boundaries for fork.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- Exact resume uses one verified watermark and matching Jidoka checkpoint.
- Recovered Console state, queues, permissions, manifest, context, and pending work match the durable oracle.
- Exactly one Session.Server starts from the exact candidate, and previously
  accepted unstarted work wakes once after `ready_exact`.
- Restore and attach make zero model and tool calls.
- Explicit continuation runs only after `ready_exact` and fresh authority checks.
- An uncertain unsafe effect is never repeated.
- Missing or changed credential-profile identity, unavailable selected reference, workspace drift, incompatible identity, or bad checkpoint fails closed.
- Exact mode never changes silently to transcript-only.
- Default and isolated Jido homes pass application-restart tests.

## Proof Artifacts

- Exact-resume precondition matrix
- Recovered-state equivalence corpus
- Zero-call restore trace
- Explicit continuation result
- Uncertainty, drift, credential, and schema denial fixtures
- Application-restart result

## Milestone Traceability

This epic delivers the exact durable resume part of the Milestone 3 outcome.
