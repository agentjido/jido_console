---
epic: M3-E15
type: epic
title: Reserve Effects and Reconcile Uncertainty
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e15
depends_on: [M3-E05, M3-E09, M3-E12, M3-E14]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E15: Reserve Effects and Reconcile Uncertainty

## Goal

Make every external model or tool effect restart-safe without automatically repeating uncertain unsafe work.

## Scope

- Reserve result identity, effective arguments, effect kind, safety class, replay policy, turn manifest, generation, and required permission before dispatch.
- Persist effect-start, Jidoka intent, completion, failure, cancellation, and uncertainty links.
- Use Jidoka journal results as execution truth and Console records as user-visible and audit truth.
- Define closed replay rules for safe, deduplicated, reconciled, and unsafe-once effects.
- Stop on an incomplete unsafe effect and expose explicit reconciliation choices.
- Reject stale generation, permission, workspace, credential reference, or manifest data before dispatch.
- Reject structurally credential-bearing effect arguments before reservation.
  At dispatch, contain the already-materialized credential value and reject an
  argument or result that would persist or expose it.
- Inject crashes at every reservation, dispatch, intent, result, and application boundary.

## Out of Scope

- Console-to-Jidoka verified watermark
- Full recovery coordinator
- User-interface reconciliation flow
- Automatic retry
- New tool or provider behavior

## Dependencies

This epic depends on M3-E05, M3-E09, M3-E12, M3-E14. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E05 exposes the approved Jidoka effect journal and store contract.
- M3-E12 supplies exact permission and control state.
- M3-E14 supplies the durable turn and workspace manifest.
- M3-E09 supplies generation fencing.

### Decisions and invariants

- No external effect starts before its reservation commits.
- Jidoka owns effect intent and result truth. Console does not invent a completed result from a runtime message.
- Completed Jidoka results replay. Incomplete effects follow the recorded policy.
- An `unsafe_once` effect with unknown outcome becomes `uncertain` and never dispatches automatically.
- A model call is an external effect and uses the same reservation and uncertainty rules.
- If an effect returns the credential value that is already in scope for the
  final call, or a structurally blocked value, keep only process-local redacted
  status, return `sensitive_result_blocked`, and stop exact continuation. Do not
  claim a durable effect result. Do not resolve a source earlier for this check.

### Delivery steps

1. Add effect reservation, state, and resolution records.
2. Add the pre-dispatch reservation barrier.
3. Link Console effect identity to Jidoka intent and result identity.
4. Implement the policy table for safe, dedupe, reconcile, and unsafe-once.
5. Add uncertainty inspection and supported reconciliation result types.
6. Fence dispatch on generation, permission, manifest, workspace, credential-reference, and sensitive-argument validity.
7. Apply the sensitive-result gate before Jidoka or Console result persistence.
8. Add deterministic provider and tool crash fixtures.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Reservation | Durable record exists before dispatch | Exact result and generation identity |
| Completed effect | Jidoka result is reused | No second provider or tool call |
| Safe incomplete | Replay follows the one recorded rule | New attempt is linked |
| Unsafe incomplete | State becomes uncertain | Zero automatic repeats |
| Stale authority | Dispatch denied before external call | No effect record advances |
| Sensitive result | Redacted typed stop with no durable result claim | Exact continuation is blocked |

### Completion boundary and handoff

M3-E16 uses these effect identities in the verified watermark and orphan state machine. M3-E24 later exposes explicit reconciliation and abandon operations.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- Every model and tool effect has one durable reservation before dispatch.
- The reservation contains exact arguments, result identity, safety class, replay rule, permission, manifest, and generation.
- Completed effects are reused through Jidoka truth.
- An uncertain unsafe effect is never repeated automatically.
- Safe and deduplicated replay follows one documented closed policy.
- Stale permission, generation, workspace, manifest, or credential-reference data cannot dispatch an effect.
- Sensitive effect arguments cannot dispatch, and a sensitive result cannot enter Jidoka, Console, logs, traces, or artifacts.
- Crash tests cover every boundary from reservation through result application.
- No client or retry user interface is added.

## Proof Artifacts

- Effect reservation and state schema
- Replay-policy matrix
- Console-to-Jidoka effect identity map
- Pre-dispatch durability trace
- Safe and unsafe crash results
- Stale-authority denial results

## Milestone Traceability

This epic satisfies the Milestone 3 rule to reserve and reconcile external effects before exact resume.
