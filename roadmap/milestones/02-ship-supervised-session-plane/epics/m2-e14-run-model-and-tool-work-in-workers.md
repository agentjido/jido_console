---
epic: M2-E14
type: epic
title: Run Model and Tool Work in Supervised Workers
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e14
depends_on: [M2-E06, M2-E13]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E14: Run Model and Tool Work in Supervised Workers

## Goal

Run model and tool work outside the session owner with typed, identity-bound results and controlled failure behavior.

## Scope

- Start model and tool work in supervised workers owned by the session lifecycle.
- Keep model calls, tool execution, streaming, and worker cleanup outside the session-server process.
- Use and validate the M2-E07 worker, run, turn, step, effect, request, and session identities.
- Convert worker events and terminal results into the M2 semantic protocol.
- Monitor worker completion, failure, timeout, and owner exit and return typed lifecycle results.
- Isolate a worker failure from unrelated session state and attached clients.
- Keep worker inputs and results data-only at the session boundary.

## Out of Scope

- New model or tool capabilities
- Remote or managed workers
- Application-restart recovery
- Durable worker journals or input receipts
- Multi-agent child ownership
- Exact drain and two-stage cancellation behavior from M2-E19 and M2-E20

## Dependencies

This epic depends on M2-E06 for the approved Jidoka request and projection contracts and on M2-E13 for the session-owner delegation boundary.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds supervised model and tool workers, use of the existing identity types, typed result handling, failure isolation, and focused tests. It must not redefine identity, add drain or cancellation policy, move worker ownership into clients, or add a remote executor.

## Acceptance Checks

- Model and tool work does not execute in the session-server process.
- Every worker result is bound to session, run, turn, step, effect, and request identity.
- A stale, duplicate, or cross-session result cannot resolve current work.
- Normal completion, failure, timeout, and owner exit produce one typed worker result and leave no untracked worker.
- A worker failure does not corrupt unrelated session history or cancel unrelated work.
- Attached clients receive semantic terminal outcomes, not raw worker state.

## Proof Artifacts

- Worker ownership and identity matrix
- Worker lifecycle and cleanup results
- Stale and duplicate result denial results
- Failure-isolation report
- Semantic projection result for model and tool outcomes

## Milestone Traceability

This epic provides the supervised worker boundary needed by the Milestone 2 session owner and current clients.
