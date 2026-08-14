---
epic: M1-E22
type: epic
title: Review, Reject, and Revert Current-Run Effects
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e22
depends_on: [M1-E15, M1-E17, M1-E21]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E22: Review, Reject, and Revert Current-Run Effects

## Goal

Give the user an exact effect review and a safe current-run revert path.

## Scope

- Record the workspace state before a coding run.
- Show the exact files and normalized effects proposed by the run.
- Consume the M1-E21 bound-approval result before an effect is applied.
- Leave the workspace unchanged after a rejected effect.
- Record the accepted effects and exact resulting diff.
- Revert only the effects from the current run.
- Preserve unrelated user changes that existed before or outside the current run.
- Report an incomplete or unsafe revert without claiming success.

## Out of Scope

- Full session history or durable resume.
- Reverting unrelated user changes.
- A claim that trusted-workspace mode is a sandbox.
- Automatic retry of an uncertain unsafe effect.
- Effect identity, normalization, and replay rules from M1-E21.

## Dependencies

This epic depends on M1-E15 for file-boundary identity, M1-E17 for process ownership, and M1-E21 for exact effect approval.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds effect snapshots, review output, bound-approval integration, rejection handling, current-run revert, and deterministic workspace tests. It must not redefine approval identity or replay rules.

## Acceptance Checks

- The review shows the exact proposed paths, operations, and normalized parameters.
- A rejected effect leaves the workspace unchanged.
- The accepted result records the exact current-run diff.
- Current-run revert restores the recorded pre-run state for current-run changes.
- Revert preserves unrelated changes that were present before the run or outside the run.
- A path-boundary or approval mismatch prevents the effect from being applied.
- An incomplete revert returns a failure result and does not claim a clean workspace.
- Repeated review and revert operations do not apply or remove another run's effects.

## Proof Artifacts

- Pre-run workspace manifest.
- Exact effect review transcript.
- Rejection and unchanged-workspace result.
- Accepted diff record.
- Current-run revert result preserving unrelated changes.
- Incomplete-revert failure result.

## Milestone Traceability

This epic covers the Milestone 1 requirement to review exact effects, keep rejection safe, and revert the current-run patch without changing unrelated workspace work.
