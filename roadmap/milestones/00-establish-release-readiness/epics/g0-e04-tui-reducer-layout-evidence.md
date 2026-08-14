---
epic: G0-E04
type: epic
title: Add TUI reducer and layout evidence
status: proposed
milestone: gate-0
depends_on: [G0-E01]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E04: Add TUI Reducer and Layout Evidence

## Goal

Prove deterministic TUI state changes and layout behavior without a terminal process.

## Scope

- Add reducer tests for each important TUI state change.
- Add layout evidence for narrow, standard, and wide terminal sizes.
- Cover Unicode display width, wrapping, clipping, and resize behavior.
- Cover streaming content, review controls, and error views.
- Use stable expected data that does not depend on wall-clock time.

## Out of Scope

- Raw terminal and PTY behavior
- Long-session evidence
- TUI redesign
- LiveView or SSH clients

## Dependencies

This epic depends on G0-E01 for the evidence result contract.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request contains reducer and layout evidence only. G0-E05 owns terminal-process evidence.

## Acceptance Checks

- Named tests cover the important reducer states.
- Width cases include narrow, standard, wide, and resize inputs.
- Unicode and multiline content have explicit expected layouts.
- Tests do not use unbounded waits or a live model.
- A layout difference produces a readable failure.

## Proof Artifacts

- Reducer test results
- Width and resize case results
- Stable layout expectations
- Coverage map from TUI states to tests

## Milestone Traceability

This epic covers the reducer and width layers of the Gate 0 TUI evidence requirement.
