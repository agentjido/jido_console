---
epic: M3-E23
type: epic
title: Add Transcript-Only Resume
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e23
depends_on: [M3-E21]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E23: Add Transcript-Only Resume

## Goal

Restore immutable Console history for inspection without claiming or granting runtime continuity.

## Scope

- Add explicit transcript-only continuity mode and result values.
- Load and validate canonical Console history, semantic snapshots, outcomes, audit data, and unresolved-state markers.
- Do not restore a Jidoka session, worker lease, pending approval authority, executable queue, or active run.
- Mark the session read-only and state why exact resume is unavailable.
- Start one generation-fenced read-only session owner from the transcript candidate.
- Report the last verified watermark, uncertain effects, pending records, and allowed next operations.
- Keep transcript-only restore provider-free and tool-free.
- Prevent exact attach from selecting this mode without an explicit caller choice.

## Out of Scope

- Exact resume
- Automatic fallback
- Retry or fork execution
- Physical store repair
- Client or renderer integration

## Dependencies

This epic depends on M3-E21. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E21 can return a `transcript_candidate` plan or a reason that no safe mode
  is available. It has not started Session.Server.
- Canonical Console history and chain validation pass.

### Decisions and invariants

- Transcript-only mode is a durable, visible continuity state and not a hidden fallback.
- It restores views, not runtime authority.
- Pending permission, queue, active run, lease, and client attachment data are descriptive only in this mode.
- No model or tool call is permitted until a later explicit retry or fork creates new authority.
- A failure to validate canonical history is repair-required, not transcript-only success.

### Delivery steps

1. Add transcript-only state and result schemas.
2. Build the read-only transcript and outcome projection from canonical history and start one read-only owner.
3. Add explicit unresolved and last-watermark summaries.
4. Disable execution, permission, queue consumption, control, and live approval operations in this mode.
5. Add exact-mode no-fallback guards.
6. Add missing Jidoka, incompatible checkpoint, uncertain effect, and valid-history fixtures.
7. Add zero-provider and zero-tool assertions.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Valid history, no Jidoka | Transcript and outcomes restore | Mode is transcript-only |
| Pending approval | Shown as historical or unresolved | Cannot approve or reject |
| Queued input | Shown but not executable | No wake-up |
| Exact attach request | Typed exact-unavailable result | No silent downgrade |
| Bad Console history | Repair-required result | No partial transcript authority |

### Completion boundary and handoff

M3-E24 adds explicit reconciliation and abandon choices. M3-E25 can create a new retry request. M3-E28 exposes the selected mode to clients.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- Transcript-only restore is explicit and visibly different from exact resume.
- It restores validated immutable history and safe derived views.
- It does not restore a Jidoka session, lease, active worker, live approval, executable queue, or client authority.
- Exactly one read-only owner starts from the transcript candidate and returns
  `ready_transcript_only` without runtime authority.
- It makes zero model and tool calls.
- Exact mode cannot fall back to it silently.
- It reports the last verified boundary and why exact resume is unavailable.
- Invalid canonical history returns repair-required instead of a successful partial view.
- Allowed next operations are bounded typed data.

## Proof Artifacts

- Transcript-only state and result contract
- Transcript equivalence fixtures
- Authority-denial matrix
- Exact-no-fallback result
- Zero-provider and zero-tool trace
- Invalid-history result

## Milestone Traceability

This epic delivers the clearly named transcript-only outcome required by the Milestone 3 goal.
