---
epic: G0-E05
type: epic
title: Add TUI terminal and endurance evidence
status: proposed
milestone: gate-0
depends_on: [G0-E01, G0-E04]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E05: Add TUI Terminal and Endurance Evidence

## Goal

Prove the current TUI behavior through bounded terminal-process tests.

## Scope

- Test raw terminal start, input, output, resize, and restore behavior.
- Test queued input, multiline input, review input, and cancellation.
- Test timing boundaries with injected or bounded time sources.
- Test a bounded long session with repeated turns and streaming output.
- Prove cleanup for readers, workers, timers, and terminal state.
- Run the required PTY flow through the production artifact.

## Out of Scope

- Reducer and layout evidence from G0-E04
- Performance measures from G0-E08
- TUI redesign
- Unbounded endurance tests

## Dependencies

This epic depends on G0-E01 for evidence identity and G0-E04 for deterministic view expectations.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request contains PTY, input, timing, cleanup, and bounded endurance evidence.

## Acceptance Checks

- The production PTY test passes with the declared terminal and OTP versions.
- Input, resize, cancellation, and terminal restore paths have explicit results.
- The long-session test has a fixed bound and finishes in CI.
- All owned processes and terminal resources stop after each test.
- Tests do not call a live model provider.
- A timeout gives a useful failure and performs cleanup.

## Proof Artifacts

- Production PTY result
- Input and cancellation results
- Long-session result and bound
- Process and terminal cleanup report
- Supported terminal and OTP assumptions

## Milestone Traceability

This epic covers terminal behavior, input, timing, and long-session evidence. It also supplies the production PTY part of the Gate 0 exit gate.
