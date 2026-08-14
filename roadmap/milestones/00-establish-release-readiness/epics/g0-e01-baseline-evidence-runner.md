---
epic: G0-E01
type: epic
title: Establish the baseline evidence runner
status: proposed
milestone: gate-0
depends_on: []
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E01: Establish the Baseline Evidence Runner

## Goal

Create one repeatable method that records and compares the current Jido Console baseline.

## Scope

- Run two clean baselines with separate source copies, build paths, dependency paths, and Git configuration.
- Run the complete test, production build, release, command, automation, artifact, and exit-status checks.
- Build the production escript and OTP release from clean state.
- Run `jido --version` and `jido --help` from the production artifact.
- Normalize allowed differences such as paths, times, and generated identifiers.
- Compare the semantic result from the two runs.
- Write a redacted machine-readable manifest and a short human-readable report.

## Out of Scope

- Product behavior changes
- Live paid model calls
- Performance measurements from G0-E08
- The final Gate 0 decision from G0-E15

## Dependencies

This epic has no Gate 0 dependency.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the runner, its tests, its result schema, and its first redacted report. It must not add the evidence owned by another epic.

## Acceptance Checks

- One command runs the complete baseline two times from isolated clean state.
- Both runs use the same tracked source and declared toolchain.
- The result manifest records separate results for test, production build, release, command, automation, artifact, and exit-status checks.
- The comparison fails when a semantic result changes.
- The comparison accepts only documented non-semantic differences.
- The escript, OTP release, version command, help command, and exit-status checks have explicit results.
- Output does not contain a credential, private path, or unredacted environment value.

## Proof Artifacts

- Baseline result schema
- Two clean-run manifests
- Semantic comparison report
- Runner test results
- Exact source and toolchain identity

## Milestone Traceability

This epic covers the current-result record, the two isolated clean runs, and the clean production builds in Gate 0. G0-E15 repeats these checks after all other Gate 0 work merges.
