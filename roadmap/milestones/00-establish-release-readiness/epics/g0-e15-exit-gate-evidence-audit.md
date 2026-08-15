---
epic: G0-E15
type: epic
title: Audit the Gate 0 exit evidence
status: proposed
milestone: gate-0
beadwork_id: jido_console-g0e15
depends_on: [G0-E01, G0-E02, G0-E03, G0-E04, G0-E05, G0-E06, G0-E07, G0-E08, G0-E09, G0-E10, G0-E11, G0-E12, G0-E13, G0-E14]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.5
---

# G0-E15: Audit the Gate 0 Exit Evidence

## Goal

Provide one explicit local audit of the complete readiness check set.

## Scope

- Run the complete baseline two times from isolated clean state.
- Confirm semantic equality and clean escript and OTP release builds.
- Confirm version, help, production PTY, and required Jidoka parity results.
- Confirm provider-free replay and divergence results.
- Confirm all hostile fixtures have controlled results and Milestone 1 links. A known-risk result is evidence of a current risk. It is not proof of safe denial. A canary disclosure fails the audit.
- Confirm the Jidoka plan, Tilde boundary, delivery graph, and traceability result.
- Record the validated Beadwork export URI, revision, time, and digest.
- Confirm release measurements, the first-user claim, and workflow controls exist.
- Record pass and fail results without changing their source data.
- Keep generated results local until a release source is frozen.

## Out of Scope

- Product changes
- A release, upload, or publish action
- Repair of a failed check
- Milestone 1 implementation

## Dependencies

This epic depends on G0-E01 through G0-E14 and merges last.

## Pull Request Boundary

The pull request adds the opt-in audit task. It does not add a generated result. Run the task again for the exact frozen source that a future release review selects.

## Acceptance Checks

- The audit can run all readiness checks or a named subset.
- Each result identifies the exact clean source, lock file, and toolchain.
- The two clean runs have the same semantic result.
- No required result is missing, stale, or from an untracked source state.
- The Beadwork export revision, digest, and freshness check match the traceability result.
- The default temporary result is removed after the run.
- An explicit output path keeps one local result for review.
- The audit does not upload or publish a product release.

## Proof Artifacts

- Local readiness audit manifest
- Two clean-run identities and comparison result
- Exit-check result matrix
- Exact source and toolchain identity

## Milestone Traceability

This epic supplies the audit mechanism. A future source-freeze review owns the certification decision and any retained result.
