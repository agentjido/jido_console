---
epic: M2-E19
type: epic
title: Add Exact Worker Drain
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e19
depends_on: [M2-E14]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E19: Add Exact Worker Drain

## Goal

Track queued and active work and prove exact worker drain before a session
reports completion.

## Scope

- Track queued work and active work by exact process-lifetime identity.
- Define the states for queued, active, draining, drained, and failed work.
- Define exact drain completion for every active work item and its owned worker
  tree.
- Keep queued work separate from active worker state.
- Report a failed drain when an owned worker or descendant cannot be accounted
  for.
- Bind drain results to the session, run, request, and worker identities.
- Do not estimate drain duration or expose a time estimate as a completion
  result.

## Out of Scope

- Graceful cancellation policy and force-kill control from M2-E20.
- Remote or durable worker recovery.
- Client adapter migration.
- A claim that process state survives an application restart.

## Dependencies

This epic depends on M2-E14 for the supervised model and tool worker boundary
and identity-bound worker results.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
queued and active work registry, exact drain state and result, worker identity
checks, and deterministic drain tests. It must not add two-stage cancellation
control or migrate a client adapter.

## Acceptance Checks

- Every queued and active work item has a session, run, request, and worker
  identity.
- The session can distinguish queued, active, draining, drained, and failed
  work.
- Drain completes only after every owned worker and descendant has stopped or
  has an explicit failed-drain result.
- A worker from another session or run cannot satisfy the current drain.
- A missing or unknown descendant fails the drain result closed.
- Drain results do not contain a duration estimate.
- Deterministic tests cover normal drain, nested workers, unknown descendants,
  duplicate results, and cross-session results.

## Proof Artifacts

- Worker and work-state identity schema
- Exact drain state transition table
- Normal and failed drain manifests
- Nested-worker and unknown-descendant test results
- Cross-session identity rejection results

## Milestone Traceability

This epic covers the Milestone 2 requirement to track queued and active work
and to define exact worker-drain behavior. It provides the drain evidence for
the graceful cancellation and worker-failure exit gates.
