---
epic: M3-E21
type: epic
title: Classify Sessions Behind a Recovery Gate
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e21
depends_on: [M3-E09, M3-E11, M3-E12, M3-E13, M3-E14, M3-E15, M3-E16, M3-E18, M3-E20]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E21: Classify Sessions Behind a Recovery Gate

## Goal

Load, validate, reconcile, rebuild, and classify a session before a continuity
mode can start its owner.

## Scope

- Add the recovery supervisor, session catalog, and bounded per-session recovery coordinator.
- Observe the completed store-wide migration gate, then run generation claim,
  history verification, Jidoka validation, reconciliation, rebuild, and
  classification in the frozen order.
- Return `exact_candidate`, `transcript_candidate`, `repair_required`, or
  `unavailable` with bounded diagnostics.
- Run at most four coordinators, queue at most 124 sessions, reserve four readers, and enforce the frozen read, diagnostic, payload, and time limits.
- Return one generation-fenced, bounded classification plan. Do not start
  Session.Server, restore runtime authority, return a ready result, or wake work.
- Identify committed accepted work in the exact candidate without waking it.
- Keep model, tool, client delivery, and normal attachment stopped.
- Prevent attach from creating a new empty session when durable load fails.

## Out of Scope

- Exact Jidoka continuation
- Transcript-only public behavior
- Client restart attachment
- Retry, fork, or abandon commands
- Archive or removal

## Dependencies

This epic depends on M3-E09, M3-E11, M3-E12, M3-E13, M3-E14, M3-E15, M3-E16, M3-E18, M3-E20. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- All durable record, generation, event, receipt, queue, manifest, effect, watermark, and store-maintenance dependencies pass.
- M2 session supervision and `Session.Client` ownership are the only live paths.

### Decisions and invariants

- Recovery work runs outside `Session.Server` and is bounded by count, bytes, time, and concurrency.
- One coordinator can load at most one 1 MiB snapshot, 1,000 suffix events or 8 MiB, and one 128 MiB Jidoka value. Other reads use bounded pages.
- One result has at most 32 diagnostics, 2 KiB each and 64 KiB total. Normal recovery stops at 30 seconds.
- A durable session has explicit create, open, recover, and attach operations. Attach never creates missing state.
- Only M3-E22 or M3-E23 can consume a complete classification plan and start
  the applicable session owner.
- `exact_candidate` requires a verified watermark and compatible Jidoka state.
  `transcript_candidate` is a classified possibility, not an implicit choice.
- Accepted unstarted work remains descriptive until M3-E22 returns `ready_exact`.
- M3-E18 completes one store-wide migration before the session catalog starts.
  A session coordinator only verifies the current schema.

### Delivery steps

1. Add the durable session catalog and bounded discovery queries.
2. Add the four-worker recovery pool, 124-item queue, reserved readers, and phase state.
3. Add current-schema verification, generation, history, Jidoka, watermark, and rebuild steps.
4. Add bounded exact-candidate and transcript-candidate plans without a server start.
5. Split create, open, recover, and attach lookup behavior.
6. Add accepted-unstarted-work classification without wake-up.
7. Add phase failure, owner crash, writer crash, missing store, corrupt store, and early-attach tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Phase order | Store gate and session phases run once in order | No per-session migration, owner, or wake |
| Exact candidate | History, watermark, Jidoka, manifest, and fence agree | One bounded classification plan |
| Degraded or blocked | Typed mode and reason returned | No implicit fallback |
| Recovery crash | Supervisor restarts from durable phase inputs | Old generation fenced |
| Attach during recovery | Typed recovering or blocked result | No empty session |
| Bounds | Recovery stops or queues at each declared limit | 4 active, 124 queued, 64 KiB diagnostics, 30 seconds |

### Completion boundary and handoff

M3-E22 and M3-E23 consume the two explicit candidate plans, start their
different owners, and return the ready results. M3-E27 uses the bounded history
source.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- Recovery follows the declared phase order and stays within its bounds.
- Recovery concurrency, queued sessions, reader use, loaded payload, diagnostics, and wall-clock time stay within their exact limits.
- A classified session cannot report ready, attach normally, start
  Session.Server, or wake execution.
- A load, current-schema, integrity, Jidoka, watermark, or repair failure cannot create empty replacement state.
- The store migration runs once before catalog recovery; no session coordinator
  owns or repeats it.
- Accepted unstarted input is identified once but is not woken in this epic.
- Recovery process failure does not corrupt durable state or grant authority.
- Exact-candidate, transcript-candidate, repair-required, and unavailable results are explicit.
- No client adapter or model continuation is implemented.

## Proof Artifacts

- Recovery topology and phase state machine
- Startup-order trace
- Candidate-plan schemas
- Early-attach and early-wake denial results
- Recovery-process crash result
- Missing, corrupt, and incompatible store results

## Milestone Traceability

This epic provides the recovery startup and readiness gate required by the Milestone 3 architecture.
