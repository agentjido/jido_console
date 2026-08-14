---
epic: M2-E29
type: epic
title: Migrate Text Output to Session.Client
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e29
depends_on: [M2-E26]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E29: Migrate Text Output to Session.Client

## Goal

Make human-readable text output a `Session.Client` projection.

## Scope

- Add a plain human-text projection through `Session.Client`.
- Render ordered semantic outcomes without renderer state in the shared session.
- Define concise text for commands, progress, outcomes, gaps, and errors.
- Keep text output separate from JSONL automation output.

## Out of Scope

- Terminal control sequences or interactive TUI rendering.
- JSON output or automation output changes.
- A new command protocol.
- Remote transports.

## Dependencies

This epic depends on M2-E26 for the completed `Session.Client` API and reusable behavior suite.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds or migrates the human-text client only.

## Acceptance Checks

- Text output consumes only `Session.Client` data and outcomes.
- Text output contains no renderer-local state, PIDs, references, functions, or raw runtime terms.
- Ordered outcomes, gaps, and errors have deterministic human-readable text.
- Text client tests pass without a terminal device.

## Proof Artifacts

- Text client contract fixture.
- Ordered text transcript.
- Gap and error projection fixture.

## Milestone Traceability

This epic covers the Milestone 2 migration of plain human text output to `Session.Client`.
