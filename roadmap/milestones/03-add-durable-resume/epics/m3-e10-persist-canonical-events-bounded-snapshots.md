---
epic: M3-E10
type: epic
title: Persist Canonical Events and Bounded Snapshots
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e10
depends_on: [M3-E03, M3-E08, M3-E09]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E10: Persist Canonical Events and Bounded Snapshots

## Goal

Make canonical Console history restart-safe while keeping semantic snapshots and replay bounded.

## Scope

- Append durable canonical Console events with stable event IDs and monotonic session sequences.
- Commit the event, sequence head, chain digest, and generation condition in one transaction.
- Persist derived renderer-neutral semantic snapshots with their source sequence and chain digest.
- Rebuild the M2 semantic state from a valid snapshot and bounded event suffix.
- Keep canonical history immutable and keep normal live updates incremental.
- Detect duplicate, missing, conflicting, stale, oversized, corrupt, and cross-session records.
- Build snapshots at the frozen interval and safe terminal, approval, hibernation, fork, and archive boundaries.

## Out of Scope

- Restart-safe input receipts
- Jidoka checkpoint watermarks
- Full startup recovery
- Client history paging
- Prompt compaction

## Dependencies

This epic depends on M3-E03, M3-E08, M3-E09. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E03 provides canonical durable record codecs and chain validation.
- M3-E08 provides the only bounded and quota-controlled writer path.
- M3-E09 provides the exact session generation fence.
- M2 semantic replay produces the same state as live reduction.

### Decisions and invariants

- A Console event becomes durable only after its immutable record, sequence head, and chain head commit together.
- An event sequence is never reused. A failed transaction does not expose its reserved sequence.
- Snapshots are derived and rebuildable. They cannot replace or delete canonical history.
- A snapshot contains bounded current semantic state, not full history.
- Recovery replay stops at 1,000 events or 8 MiB and returns `snapshot_rebuild_required` when it cannot reach the head.

### Delivery steps

1. Add durable event append and exact duplicate lookup.
2. Add chain-head and sequence-head conditional updates.
3. Add bounded semantic snapshot encoding and verification.
4. Add snapshot selection and bounded suffix replay.
5. Integrate durable append after M2 canonical projection and before client delivery.
6. Add invalid-order, duplicate, torn-state, bad-snapshot, and oversize tests.
7. Measure snapshot size, suffix count, replay bytes, and rebuild time.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Event commit | Record, sequence, chain, and head commit together | Exact generation and event identity |
| Duplicate | Same identity and digest returns existing record | No new sequence |
| Conflict | Same identity or sequence with different digest fails | State unchanged |
| Snapshot | Replay from snapshot plus suffix equals full canonical replay | 1 MiB and suffix bounds |
| Bad snapshot | Earlier valid snapshot or typed rebuild result | Canonical events unchanged |

### Completion boundary and handoff

M3-E11 adds receipts that commit with admission events. M3-E16 links selected execution events to Jidoka checkpoints. M3-E27 later exposes bounded history pages.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- Every durable event has one stable ID, monotonic sequence, generation, schema, and chain digest.
- No acknowledged event is lost after store or application restart.
- Duplicate input cannot create a second event or sequence.
- Live and durable replay produce the same M2 semantic state.
- Snapshots stay at or below 1 MiB and do not contain complete history.
- Replay stays within the event and byte bounds.
- A corrupt derived snapshot never changes canonical history.
- Normal client delivery remains incremental.

## Proof Artifacts

- Durable event schema and append result
- Sequence and digest-chain fixtures
- Live-versus-replay equivalence result
- Snapshot size and cadence measurements
- Bounded suffix replay result
- Corrupt snapshot recovery result

## Milestone Traceability

This epic provides immutable Console history and bounded semantic rebuild for restart recovery.
