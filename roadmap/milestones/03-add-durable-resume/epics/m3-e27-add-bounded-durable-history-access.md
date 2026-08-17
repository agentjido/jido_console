---
epic: M3-E27
type: epic
title: Add Bounded Durable History Access
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e27
depends_on: [M3-E10, M3-E21]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E27: Add Bounded Durable History Access

## Goal

Let large recovered sessions attach and inspect history without sending an unbounded full transcript.

## Scope

- Define a versioned bounded current-state snapshot that excludes complete history.
- Define ordered history-page and suffix requests with session, generation, range, schema, and digest identities.
- Keep attach and explicit recovery snapshots at or below the M2 protocol limit.
- Return bounded pages by item count and encoded bytes.
- Limit each page to 128 records and 1 MiB including a page token of at most 4 KiB.
- Validate stale, future, overlapping, missing, cross-session, malformed, and oversized ranges.
- Preserve old additive protocol input rules and normal incremental live output.
- Add history paging to the reusable Session.Client contract suite without migrating clients.

## Out of Scope

- Session.Client restart attachment
- TUI scroll behavior
- Search or analytics
- Remote transport
- Canonical event deletion

## Dependencies

This epic depends on M3-E10, M3-E21. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E10 supplies immutable event ranges and bounded semantic snapshots.
- M3-E21 supplies the recovered generation and exact or transcript candidate
  classification. History paging itself does not require a ready session owner.
- M2 client gap recovery and protocol bounds remain frozen compatibility inputs.

### Decisions and invariants

- Attach returns current semantic state, continuity metadata, and a sequence baseline. It does not return complete history.
- Older transcript history uses pull-based bounded pages.
- A page token is bound to session, generation, source range, schema, and digest.
- Live delivery starts after the attach snapshot sequence and remains incremental.
- History paging grants no execution or permission authority.

### Delivery steps

1. Add current-state snapshot and history-page protocol values.
2. Add bounded store queries and page tokens.
3. Add range, digest, identity, version, and size validation.
4. Extend the local Session.Client behavior and contract suite.
5. Add large-session, stale-token, cross-session, overlap, gap, and malformed fixtures.
6. Prove old supported input and additive field behavior.
7. Measure page bytes, snapshot bytes, calls, and replay equivalence.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Large attach | Current snapshot fits the protocol bound | No full history payload |
| History page | Ordered records match canonical range | Count and byte bounds |
| Stale token | Typed stale-generation result | No data from new generation |
| Cross-session token | Denied | No data leakage |
| Live output | Begins at next sequence and stays incremental | No repeated snapshot |

### Completion boundary and handoff

M3-E28 uses this contract for restart attachment. M3-E31 and M3-E32 consume it through Session.Client.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- A supported large session can attach without a full-history snapshot.
- Current-state snapshots stay within 1 MiB.
- History pages stay within count and byte limits and preserve canonical order.
- A history page contains at most 128 records and 1 MiB, and its token stays at or below 4 KiB.
- Tokens are bound to exact session, generation, schema, range, and digest.
- Invalid, stale, future, malformed, and cross-session requests fail without state change.
- Normal live output remains incremental.
- Paged replay produces the same transcript as canonical history.
- No production client is migrated in this epic.

## Proof Artifacts

- Current-state snapshot schema
- History-page and token contract
- Large-session attach result
- Invalid-range and token fixtures
- Paged replay equivalence
- Snapshot and page size measurements

## Milestone Traceability

This epic closes the large-history gap between bounded M2 client snapshots and durable M3 sessions.
