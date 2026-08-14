---
epic: M2-E23
type: epic
title: Separate Model Content from View Details
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e23
depends_on: [M2-E14, M2-E22]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E23: Separate Model Content from View Details

## Goal

Return concise model content together with typed structured view details so
clients can render the same semantic result without copying renderer data.

## Scope

- Define the concise model-content result for a completed semantic turn.
- Define typed structured view details for status, progress, tool activity,
  permissions, diagnostics, and other client-facing details.
- Keep model content separate from view details in events, outcomes, and
  snapshots.
- Preserve provenance, sensitivity, durability, and trust data for each result.
- Keep view details renderer-neutral and safe for bounded client delivery.
- Preserve bounded unknown view fields without granting authority.

## Out of Scope

- Typed command-effect definitions owned by M2-E22.
- Client-specific rendering or adapter migration.
- Model provider support qualification.
- Durable session recovery.

## Dependencies

This epic depends on M2-E14 for the model and tool worker-result boundary and
M2-E22 for typed command effects.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the model
content and view-detail schemas, validators, sensitivity rules, and
deterministic result tests. It must not change a client adapter or add a model
provider.

## Acceptance Checks

- A completed turn returns concise model content and typed view details in
  separate fields.
- View details contain no renderer-specific structures, PIDs, references, or
  functions.
- Content and view details preserve their declared sensitivity, durability,
  provenance, and trust data.
- Unknown bounded view fields remain data and cannot grant authority.
- Clients can omit view details without changing command meaning or model
  content.
- Deterministic tests cover content-only, view-only, combined, invalid, and
  sensitive result cases.

## Proof Artifacts

- Model-content and view-detail schema
- Result validation and sensitivity table
- Renderer-neutral structured view examples
- Unknown-field safety results
- Content and view separation test results

## Milestone Traceability

This epic covers the Milestone 2 requirement to return concise model content
separately from structured view details.
