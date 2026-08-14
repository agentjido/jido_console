---
epic: M2-E04
type: epic
title: Generate Protocol Types and Validators
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e04
depends_on: [M2-E03]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E04: Generate Protocol Types and Validators

## Goal

Keep protocol types and validation behavior consistent across Elixir and non-Elixir clients.

## Scope

- Generate Elixir protocol types from the canonical schema.
- Generate non-Elixir protocol types from the canonical schema.
- Generate validators for commands, events, interactions, outcomes, snapshots, replay data, and controls.
- Add drift checks that fail when generated output does not match the schema.
- Preserve bounded unknown data without granting it authority.
- Reject invalid versions, unknown authority fields, oversized values, and invalid shapes.
- Add deterministic fixture tests for valid, invalid, and bounded-unknown protocol data.

## Out of Scope

- Changes to the canonical schema.
- Jidoka projection or Console event reduction.
- Client transport implementations.
- Durable storage.

## Dependencies

This epic depends on M2-E03 for the canonical session protocol schema.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request contains generators, generated types, validators, drift CI, and protocol fixture tests. It must not change the protocol meaning or add a client implementation.

## Acceptance Checks

- Generated Elixir types validate the canonical protocol.
- Generated non-Elixir types validate the same protocol shapes and versions.
- Drift CI fails when generated output differs from the canonical schema.
- Bounded unknown data is retained only within declared limits.
- Unknown data cannot add authority, permissions, or control.
- Invalid versions and malformed data fail with stable errors.
- The same fixture corpus passes or fails consistently across generated validators.

## Proof Artifacts

- Generator and generated-output identity record.
- Elixir validator results.
- Non-Elixir validator results.
- Drift CI result.
- Unknown-data and authority-denial results.

## Milestone Traceability

This epic covers the Milestone 2 requirement to generate protocol types and validators from one canonical schema and to preserve bounded unknown data without granting authority.
