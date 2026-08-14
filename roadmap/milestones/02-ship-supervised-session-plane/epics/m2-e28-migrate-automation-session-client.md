---
epic: M2-E28
type: epic
title: Migrate Automation to Session.Client
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e28
depends_on: [M2-E26]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E28: Migrate Automation to Session.Client

## Goal

Make automation use `Session.Client` without changing its published contracts.

## Scope

- Migrate automation commands and execution flow to the `Session.Client` contract.
- Preserve command schemas, run artifacts, JSONL output, and exit statuses.
- Preserve one fresh Jidoka session for each evaluation matrix cell.
- Map ordered semantic outcomes into the existing automation result and artifact contracts.

## Out of Scope

- Changes to published automation schemas or exit-status meanings.
- Shared state between evaluation matrix cells.
- TUI, text, or JSON client migration.
- Application-restart recovery.

## Dependencies

This epic depends on M2-E26 for the completed `Session.Client` API and reusable behavior suite.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request migrates automation only and preserves the existing public automation contracts.

## Acceptance Checks

- `jido run` and `jido eval` use `Session.Client` without a private session-owner path.
- Command schemas, artifacts, JSONL records, and exit statuses remain backward-compatible.
- Each matrix cell has one fresh session and cannot observe another cell's state.
- Provider-free replay and cancellation results remain deterministic.
- Automation contract and artifact-integrity tests pass.

## Proof Artifacts

- Automation client contract result.
- JSONL compatibility fixture result.
- Artifact compatibility result.
- Matrix-cell isolation result.

## Milestone Traceability

This epic covers the Milestone 2 migration of automation to `Session.Client`.
