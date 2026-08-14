---
epic: M1-E17
type: epic
title: Own Complete Child-Process Trees
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e17
depends_on: [M1-E13]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E17: Own Complete Child-Process Trees

## Goal

Own and stop every child process created by restricted work.

## Scope

- Create one owner for each restricted child-process tree.
- Track descendants without granting them new authority.
- Stop the complete tree on normal completion.
- Stop the complete tree on rejection, cancel, timeout, and owner exit.
- Report an unclean or unknown descendant as a failed cleanup result.
- Remove process-local temporary state after confirmed cleanup.
- Add controlled parent-and-child fixtures for each termination path.

## Out of Scope

- Network policy.
- General remote or container executors.
- Process recovery after application restart.
- Unbounded process supervision outside a restricted run.

## Dependencies

This epic depends on M1-E13 for the restricted profile and execution ownership contract.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds child-tree ownership, termination controls, cleanup evidence, and focused process fixtures.

## Acceptance Checks

- The owner can identify every process created by a restricted run without exposing unstable identifiers in user evidence.
- Normal completion leaves no child process.
- Rejection leaves no child process.
- Cancel leaves no child process.
- Timeout leaves no child process.
- Owner exit leaves no child process.
- A failed cleanup is visible and blocks a safe completion result.
- The Gate 0 hostile runtime-boundary process fixtures pass.

## Proof Artifacts

- Child-process ownership contract.
- Parent-and-child cleanup results for all five exit paths.
- Failed-cleanup result and diagnostic record.
- Temporary-state cleanup result.
- Gate 0 process-tree report.

## Milestone Traceability

This epic covers the Milestone 1 requirement to own and stop the complete child-process tree on normal completion, rejection, cancel, timeout, and owner exit.
