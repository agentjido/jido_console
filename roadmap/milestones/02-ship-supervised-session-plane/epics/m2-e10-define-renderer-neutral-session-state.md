---
epic: M2-E10
type: epic
title: Define Renderer-Neutral Session State
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e10
depends_on: [M2-E04, M2-E08]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E10: Define Renderer-Neutral Session State

## Goal

Compose one semantic session state that all current clients can project without renderer or live runtime state.

## Scope

- Compose the shared session state from the generated protocol types and classified Console events.
- Keep shared state free of terminal cells, ANSI text, DOM data, viewport state, client drafts, PIDs, references, functions, and raw runtime structs.
- Separate canonical semantic history from client-local input and navigation state.
- Define the initial state and the allowed semantic state fields for history, transcript, outcomes, controls, queues, and active-run summaries.
- Add recursive invariants that reject renderer values and live runtime values anywhere in shared state.
- Keep state composition data-only and independent of a client or transport.

## Out of Scope

- Session process supervision
- Application-restart recovery or durable input receipts
- LiveView, SSH, or external client deployment
- Runtime event projection implementation
- Extension loading
- Protocol schema, version, generation, and event-classification changes

## Dependencies

This epic depends on M2-E04 for generated protocol types and validators and on M2-E08 for Console event identity and classification.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds semantic state composition, state invariants, and focused tests. It must not redefine the protocol or event classes, add a session owner, or add a client transport.

## Acceptance Checks

- One semantic state model composes only generated protocol values and classified events.
- Shared state contains no renderer data, process handles, references, functions, or raw runtime structures.
- Client-local drafts and navigation state cannot enter shared semantic history.
- History, transcript, outcomes, controls, queues, and active-run summaries have explicit data-only fields.
- Recursive validation rejects a forbidden value at any nesting depth with a focused reason.
- State composition has no client or transport dependency.

## Proof Artifacts

- Semantic state composition and field map
- Initial-state and state-invariant results
- Renderer-data exclusion checks
- Live-runtime exclusion checks

## Milestone Traceability

This epic defines the renderer-neutral semantic state required by the Milestone 2 session owner and current-client migration.
