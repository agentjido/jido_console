---
epic: M2-E30
type: epic
title: Migrate JSON Output to Session.Client
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e30
depends_on: [M2-E26]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E30: Migrate JSON Output to Session.Client

## Goal

Make JSON output a JSON-compatible semantic `Session.Client` adapter.

## Scope

- Add a JSON-compatible semantic client adapter through `Session.Client`.
- Preserve `Jido.Cli.Automation.JSONL` as the only writer of automation standard output and run artifacts.
- Keep bounded unknown data without granting authority.
- Project ordered outcomes, snapshots, gaps, and errors into JSON-compatible values.

## Out of Scope

- A second JSONL writer.
- Breaking changes to automation JSONL schemas.
- Raw runtime terms or client-local renderer data in JSON values.
- Remote JSON transport.

## Dependencies

This epic depends on M2-E26 for the completed `Session.Client` API and reusable behavior suite.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request migrates the JSON client adapter only and does not change unrelated automation behavior.

## Acceptance Checks

- The JSON adapter uses `Session.Client` and produces JSON-compatible values only.
- `Jido.Cli.Automation.JSONL` remains the only automation standard-output and artifact writer.
- Unknown data is bounded, preserved as data, and cannot grant authority.
- JSON output preserves ordered semantic identity and reports gaps explicitly.
- JSON encoding and automation output tests pass.

## Proof Artifacts

- JSON client contract fixture.
- JSON encoding result.
- Unknown-data boundary fixture.
- JSONL writer ownership result.

## Milestone Traceability

This epic covers the Milestone 2 migration of JSON output to `Session.Client`.
