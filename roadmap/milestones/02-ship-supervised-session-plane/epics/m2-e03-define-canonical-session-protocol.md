---
epic: M2-E03
type: epic
title: Define the Canonical Session Protocol
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e03
depends_on: []
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.8
---

# M2-E03: Define the Canonical Session Protocol

## Goal

Define one versioned protocol for all current Jido Console session clients.

## Scope

- Define versioned command types.
- Define versioned event types.
- Define versioned interaction and response types.
- Define versioned outcome types.
- Define versioned snapshot and replay types.
- Define versioned control types for cancel, force kill, attach, detach, and recovery.
- Define JSON-compatible forms for protocol data.
- Define protocol version and compatibility rules.
- Define which data is client-local and which data is shared session state.

## Out of Scope

- Generated language bindings and validators from M2-E04.
- Jidoka event projection.
- Session-server implementation.
- Durable storage or restart-safe input.

## Dependencies

This epic starts from the approved Milestone 1 client contracts and source
baseline on `main`. Deferred public v0.1 publication in M1-E30 does not block
this work.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request contains the protocol schema, version rules, JSON-compatible shapes, and compatibility decisions. It must not add generated bindings, runtime ownership, or client migration.

## Acceptance Checks

- The schema defines command, event, interaction, outcome, snapshot, replay, and control types.
- Every type has a version and an explicit compatibility rule.
- Protocol data has a JSON-compatible representation.
- Client-local input and navigation cannot enter shared session state through the schema.
- The schema defines bounded sizes and unknown-data behavior.
- The schema has no field that grants authority from a renderer, transport, host, or origin.

## Proof Artifacts

- Versioned canonical protocol schema.
- Protocol type and compatibility matrix.
- JSON-compatible example corpus.
- Client-local versus shared-state decision record.
- Bounded-data and authority review.

## Milestone Traceability

This epic covers the Milestone 2 requirement to define a versioned semantic command, event, interaction, outcome, snapshot, replay, and control protocol.
