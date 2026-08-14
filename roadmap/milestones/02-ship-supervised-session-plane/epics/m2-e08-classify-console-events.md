---
epic: M2-E08
type: epic
title: Classify Console Events
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e08
depends_on: [M2-E04, M2-E07]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E08: Classify Console Events

## Goal

Give every Console event stable ordering, storage, sensitivity, origin, and trust data.

## Scope

- Define the monotonic session-sequence field and allocation rule for each Console event.
- Assign a durability class.
- Assign a sensitivity class.
- Assign an origin record.
- Assign trust data that describes evidence and policy state.
- Preserve process-lifetime identities on event records.
- Define event validation and classification errors.
- Keep origin as descriptive data and never use it as authority.
- Keep event records JSON-compatible and free of raw runtime structures.
- Reserve live sequence allocation for the owning session server.

## Out of Scope

- Durable event storage.
- Jidoka projection implementation.
- Client delivery and replay transport.
- Authority grants from event origin.

## Dependencies

This epic depends on M2-E04 for generated protocol types and M2-E07 for process-lifetime identities.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds event classification, validation, sequence rules, and fixture tests. It must not add durable storage or client delivery.

## Acceptance Checks

- Every admitted Console event has one monotonic session sequence that the session owner allocates.
- Every event has durability, sensitivity, origin, and trust data.
- Event identity preserves the related process-lifetime identities.
- Invalid sequence or classification data fails clearly.
- Origin data cannot grant authority or bypass policy.
- Event records contain no PIDs, references, functions, or raw runtime structures.
- Event fixtures validate through the generated protocol validators.
- Event classification code cannot keep or allocate live session sequence state.

## Proof Artifacts

- Console event schema and classification matrix.
- Sequence and identity fixture results.
- Durability and sensitivity classification results.
- Origin-no-authority test result.
- Raw-runtime exclusion scan.

## Milestone Traceability

This epic covers the Milestone 2 requirement to give each Console event a monotonic sequence, durability class, sensitivity class, origin, and trust data.
