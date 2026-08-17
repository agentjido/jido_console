---
epic: M3-E28
type: epic
title: Attach Session.Client After Restart
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e28
depends_on: [M3-E09, M3-E22, M3-E23, M3-E27]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E28: Attach Session.Client After Restart

## Goal

Attach every client to a recovered session through the same renderer-neutral Session.Client boundary.

## Scope

- Add explicit exact and transcript-only continuity options to attach.
- Return typed recovering, exact-unavailable, transcript-only, repair-required, unavailable, and ready results.
- Create a new generation-bound client and attachment identity after restart.
- Return the bounded current-state snapshot and continuity metadata.
- Start delivery after the snapshot sequence and use M2 gap recovery for later live gaps.
- Reject every old-generation handle, acknowledgement, recovery token, and client operation.
- Prevent attach from creating a missing or failed durable session.

## Out of Scope

- CLI, automation, or TUI workflow changes
- A second durable client API
- Raw Jidoka or runtime subscriptions
- Remote transport
- Automatic execution on attach

## Dependencies

This epic depends on M3-E09, M3-E22, M3-E23, M3-E27. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E22 and M3-E23 supply explicit ready continuity modes.
- M3-E27 supplies bounded snapshot and history access.
- M3-E09 supplies generation fencing.
- The complete M2 Session.Client contract and bypass guards pass.

### Decisions and invariants

- Exact attach never falls back. Transcript-only attach is an explicit caller choice.
- Every restart attachment gets a new client and attachment identity in the current generation.
- Process-local delivery acknowledgement and gap tokens do not survive restart.
- Attach performs no model or tool call and sends no execution wake-up.
- All semantic data continues through canonical Console protocol values.

### Delivery steps

1. Extend attach request, result, capabilities, and continuity metadata.
2. Connect attach to recovery readiness lookup without implicit session creation.
3. Create generation-bound client and attachment records.
4. Return the bounded snapshot and establish the live delivery baseline.
5. Connect history access and existing live gap recovery.
6. Add stale-handle and old-token rejection to every client operation.
7. Run the reusable client suite across restart, recovery phase, exact, transcript-only, and failure cases.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Exact ready | New attachment and exact snapshot return | Next live sequence is correct |
| Transcript-only | New read-only attachment returns | Mode is explicit |
| Recovering or blocked | Typed result with bounded phase data | No attachment or empty session |
| Old handle | All operations fail stale generation | Current state unchanged |
| Attach side effects | Zero provider, tool, or wake calls | Canonical client path only |

### Completion boundary and handoff

M3-E31 adds CLI text, CLI JSON, and automation operations. M3-E32 adds TUI
workflows. M3-E33 proves all production clients against the applicable-client
matrix.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- A client attaches after restart through Session.Client only.
- Exact and transcript-only attach choices are explicit and never interchangeable.
- A restart creates new client and attachment identities in the current generation.
- The snapshot and history path stay bounded.
- Live delivery resumes at the exact next sequence.
- Old handles, acknowledgements, gaps, recovery tokens, and operations cannot affect current state.
- Recovering, repair-required, unavailable, missing, and incompatible sessions do not become empty sessions.
- Attach makes no model or tool call and introduces no raw runtime path.

## Proof Artifacts

- Restart attach API and continuity schema
- Reusable client contract result
- Exact and transcript-only attach traces
- Recovery-phase and missing-session results
- Old-handle and token denial matrix
- No-raw-path and zero-call results

## Milestone Traceability

This epic connects durable restart recovery to the renderer-neutral client architecture from Milestone 2.
