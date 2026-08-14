---
epic: M1-E18
type: epic
title: Add the Model Commands
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e18
depends_on: [M1-E06, M1-E07, M1-E09, M1-E10, M1-E11, M1-E12]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E18: Add the Model Commands

## Goal

Give users exact, safe model support information from the command line.

## Scope

- Add `jido models list`.
- Add `jido models show`.
- Add `jido models test`.
- Show provider, model, support tier, capabilities, limits, cost class, cancellation behavior, prompt-cache support, and known gaps.
- Redact credential values and sensitive provider details from command output.
- Make `models test` use the declared provider contract and execution profile.
- Fail before a turn when a required model feature is not supported.
- Make offline mode report a clear denial for a model test that needs a network call.

## Out of Scope

- TUI `/model` and `/profile` selection.
- Silent provider or model fallback.
- New provider support claims without contract evidence.
- Durable model-turn records.

## Dependencies

This epic depends on M1-E06, M1-E07, M1-E09, M1-E10, M1-E11, and M1-E12 for the catalog, contract harness, capability and offline policy, and provider qualification records.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the three model commands, their schemas, redacted output, and deterministic contract tests.

## Acceptance Checks

- `jido models list` lists only declared model records and support tiers.
- `jido models show` reports exact support data for one model.
- `jido models test` reports contract success, bounded failure, or unsupported status.
- Command output contains no credential value.
- A required unsupported capability fails before the turn starts.
- Offline mode blocks a model test that would call a provider.
- Output is stable for automation and uses the documented exit statuses.

## Proof Artifacts

- Model command schema and help output.
- Redacted list and show results.
- Provider-free model test results.
- Supported-provider bounded contract results.
- Unsupported-capability and offline-denial results.

## Milestone Traceability

This epic covers the Milestone 1 requirement to add `jido models list`, `jido models show`, and `jido models test` with exact support and capability data.
