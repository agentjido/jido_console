---
epic: M2-E09
type: epic
title: Project Jidoka Events at One Boundary
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e09
depends_on: [M2-E06, M2-E08]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.1.0
---

# M2-E09: Project Jidoka Events at One Boundary

## Goal

Convert Jidoka events into Console events at one controlled projection boundary.

## Scope

- Consume Jidoka events only through the approved integration facade.
- Project each event into the classified Console event shape.
- Preserve Jidoka request, turn, step, and event identities.
- Dedupe duplicate Jidoka events without creating duplicate Console events.
- Reject invalid event order with a clear result.
- Accept the next Console sequence from the owning caller without keeping live sequence state.
- Keep raw runtime data out of Console events.
- Make this projection the only allowed source of client-visible runtime events. Client migration remains in later epics.
- Keep projection behavior deterministic and bounded.

## Out of Scope

- Session-server ownership.
- Durable event storage.
- Renderer-specific projection.
- Direct access to private Jidoka runtime modules.

## Dependencies

This epic depends on M2-E06 for the pinned Jidoka integration and M2-E08 for Console event classification.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds one projection boundary, identity preservation, deduplication, order checks, and deterministic fixtures.

## Acceptance Checks

- All Console event projection uses one documented boundary.
- Jidoka identities are preserved in the resulting Console events.
- Duplicate Jidoka events produce no duplicate Console event.
- Invalid Jidoka order fails clearly and does not corrupt semantic state.
- Unknown bounded data remains bounded and cannot grant authority.
- Console events contain no raw Jidoka runtime structures.
- The client protocol has no raw Jidoka or runtime-event alternative to this projection.
- Projection results are deterministic for the same input stream.
- The projection boundary cannot allocate or own the live Console sequence.

## Proof Artifacts

- Projection-boundary API record.
- Jidoka-to-Console identity map.
- Duplicate-event result.
- Invalid-order result.
- Raw-runtime exclusion and bounded-data results.

## Milestone Traceability

This epic covers the Milestone 2 requirement to project canonical Jidoka events at one boundary, preserve runtime identities, deduplicate events, and reject invalid order.
