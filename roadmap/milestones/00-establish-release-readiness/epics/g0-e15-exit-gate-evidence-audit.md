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

Record one final Gate 0 decision from the complete merged evidence set.

## Scope

- Run the complete baseline two times from isolated clean state.
- Confirm semantic equality and clean escript and OTP release builds.
- Confirm version, help, production PTY, and required Jidoka parity results.
- Confirm provider-free replay and divergence results.
- Confirm all hostile fixtures have controlled results and Milestone 1 links. A known-risk result is evidence of a current risk. It is not proof of safe denial. A canary disclosure fails the audit.
- Confirm the Jidoka plan, Tilde boundary, delivery graph, and traceability result.
- Record the validated Beadwork export URI, revision, time, and digest.
- Confirm release measurements, the first-user claim, and workflow controls exist.
- Record pass, fail, blocked, and waived results without changing evidence.

## Out of Scope

- Product changes
- A release or publish action
- Repair of a failed check
- Milestone 1 implementation

## Dependencies

This epic depends on G0-E01 through G0-E14 and merges last.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the final evidence manifest and decision record only. A failed check must return to its owning epic or a new approved corrective epic.

## Acceptance Checks

- Every Gate 0 work item has a linked result.
- Every Gate 0 exit check has a current result from the declared source identity.
- The two clean runs have the same semantic result.
- No required result is missing, stale, or from an untracked source state.
- The Beadwork export revision, digest, and freshness check match the traceability result.
- A waiver names its authority, reason, limit, and end condition and cannot hide an exit-gate failure.
- The final record gives one explicit decision: pass, fail, or blocked.
- The audit does not publish a product release.

## Proof Artifacts

- Final Gate 0 evidence manifest
- Two clean-run identities and comparison result
- Exit-check result matrix
- Open-risk and waiver record
- Gate 0 decision record

## Milestone Traceability

This epic audits all Gate 0 work and exit requirements. It authorizes Milestone 1 work only when the exit gate passes.
