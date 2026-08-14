---
epic: M1-E08
type: epic
title: Resolve Credentials and Add Diagnostics
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e08
depends_on: [M1-E02, M1-E06]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E08: Resolve Credentials and Add Diagnostics

## Goal

Resolve provider credentials from declared sources and give users safe authentication and health diagnostics.

## Scope

- Define the stable credential source contract for each supported provider.
- Resolve credentials only from declared sources and only for the requested operation.
- Give host variables precedence over an explicitly selected private environment file.
- Add `jido auth status`, `jido auth doctor`, and `jido doctor`.
- Report missing, invalid, or unusable credentials without showing their values.
- Keep credentials out of command arguments, configuration, durable state, events, logs, traces, artifacts, and session data.
- Bind diagnostics to the exact model catalog identity and provider contract context.

## Out of Scope

- Adding provider support claims
- Storing credential values in Jido Home
- Accepting API keys in command arguments
- Automatic provider fallback
- Credential management for remote or multi-user operation

## Dependencies

This epic depends on M1-E02 for the Jido Home and local configuration boundary and M1-E06 for exact provider and model identities.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds credential resolution, redacted diagnostics, and focused tests. It must not print, persist, or publish credential values.

## Acceptance Checks

- Each provider resolves credentials only from its declared source contract.
- Host variables take precedence over a selected private environment file.
- No command accepts a credential value through an argument.
- Status, doctor output, errors, logs, events, traces, artifacts, and session data contain no credential value.
- Missing and invalid credentials return stable, actionable, redacted reasons.
- Diagnostics do not perform an unbounded provider call or change the selected model.

## Proof Artifacts

- Credential source and precedence table
- Redacted resolution and diagnostics results
- Negative tests for argument, configuration, log, and artifact leakage
- `jido auth status`, `jido auth doctor`, and `jido doctor` result examples

## Milestone Traceability

This epic supplies the credential and diagnostics controls required before the Milestone 1 provider and offline policy gates can run.
