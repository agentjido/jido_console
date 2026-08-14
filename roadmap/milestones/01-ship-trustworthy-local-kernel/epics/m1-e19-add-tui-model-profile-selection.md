---
epic: M1-E19
type: epic
title: Add TUI Model and Profile Selection
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e19
depends_on: [M1-E13, M1-E18]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E19: Add TUI Model and Profile Selection

## Goal

Let a user select the model and execution profile before work starts.

## Scope

- Add `/model` selection to the TUI.
- Add `/profile` selection to the TUI.
- Show the selected model, provider, support tier, and effective settings before work starts.
- Show the effective restricted or trusted-workspace profile and its warning.
- Reject an unavailable model or profile before a turn starts.
- Keep model and profile selection out of durable tool or credential data.
- Preserve current TUI input, output, cancellation, and exit behavior.

## Out of Scope

- Provider fallback consent.
- Exact effect approval.
- New provider support contracts.
- Session ownership and durable resume.

## Dependencies

This epic depends on M1-E13 for the profile contract and M1-E18 for model command and support data.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds TUI model/profile actions, effective-setting display, and deterministic interaction tests.

## Acceptance Checks

- `/model` lists only models allowed by the support catalog.
- `/profile` lists only profiles allowed by the local policy.
- The TUI shows the effective model and settings before work starts.
- The TUI labels trusted-workspace mode as not a sandbox.
- An unavailable model or profile prevents the turn from starting.
- A changed selection is visible in the run configuration and is not applied silently.
- Existing TUI input, cancellation, cleanup, and exit-status contracts pass.

## Proof Artifacts

- `/model` interaction transcript.
- `/profile` interaction transcript.
- Effective-setting display result.
- Invalid-selection denial result.
- TUI compatibility and cleanup test results.

## Milestone Traceability

This epic covers the Milestone 1 requirement to add `/model` and `/profile` selection and to show the effective model and settings before work starts.
