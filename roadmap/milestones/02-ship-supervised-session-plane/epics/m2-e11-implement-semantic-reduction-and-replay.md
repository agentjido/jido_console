---
epic: M2-E11
type: epic
title: Implement Semantic Reduction and Replay
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e11
depends_on: [M2-E09, M2-E10]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E11: Implement Semantic Reduction and Replay

## Goal

Reduce ordered semantic events into session state and prove that replay matches live reduction.

## Scope

- Implement pure reduction for the versioned session state from M2-E10.
- Apply commands, interactions, controls, and Jidoka projections through the same reduction boundary.
- Preserve event identity and sequence checks during live application and replay.
- Define snapshots that contain semantic state and bounded recovery metadata only.
- Replay the same event stream and compare the transcript, outcomes, and relevant state.
- Reject duplicate, invalid-order, stale, and cross-session events.
- Keep client-local drafts outside the replay input.

## Out of Scope

- Application-restart recovery
- A durable Console-to-Jidoka watermark
- Durable input acknowledgement
- Session supervision topology
- Client delivery backpressure

## Dependencies

This epic depends on M2-E09 for the Jidoka projection boundary and M2-E10 for the semantic state and protocol definitions.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the reducer, replay path, snapshot types, and deterministic tests. It must not add process supervision or persistent storage recovery.

## Acceptance Checks

- Live reduction and replay produce the same transcript and semantic outcomes from the same valid events.
- Duplicate events do not create duplicate semantic state.
- Invalid order, stale identity, and cross-session events fail clearly.
- Snapshots contain only approved semantic data and bounded metadata.
- Replay does not call a model, tool, or renderer.
- Client-local input and navigation state do not change replay results.

## Proof Artifacts

- Pure reducer and replay result
- Snapshot schema and validation result
- Duplicate and invalid-order denial results
- Cross-session identity denial results
- Live-versus-replay equivalence report

## Milestone Traceability

This epic supplies semantic replay and snapshot behavior for the Milestone 2 exit gate and later client recovery from delivery gaps.
