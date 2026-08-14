---
epic: G0-E07
type: epic
title: Add hostile runtime-boundary fixtures
status: proposed
milestone: gate-0
depends_on: [G0-E01, G0-E06]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E07: Add Hostile Runtime-Boundary Fixtures

## Goal

Create controlled fixtures that show the current network and process-cleanup boundary.

## Scope

- Add undeclared loopback and external-network access cases.
- Use controlled local endpoints or safe test doubles. Do not contact a public service.
- Add a process-tree fixture with a parent and child process.
- Test cleanup after success, rejection, cancellation, timeout, and owner exit.
- Classify each result as denied, known risk, or not applicable.
- Link each known risk to the Milestone 1 control that must close it.

## Out of Scope

- File-boundary cases from G0-E06
- Restricted-execution implementation
- Calls to a real external network endpoint
- Managed or remote executors

## Dependencies

This epic depends on G0-E01 for evidence identity and G0-E06 for hostile-fixture conventions.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds network and process fixtures, cleanup checks, result classes, and focused tests.

## Acceptance Checks

- Network cases use no public endpoint and make no paid call.
- The test runner stops all fixture-owned processes, including after a known-risk product result.
- Each termination path has an explicit result.
- The runner detects an unexpected network or process result.
- Reports contain no secret, unstable process identifier, or private path.
- Each known risk links to planned Milestone 1 work.

## Proof Artifacts

- Runtime-boundary fixture manifest
- Network access results
- Process-tree cleanup results
- Milestone 1 risk links

## Milestone Traceability

This epic covers network access and child-process cleanup in the Gate 0 hostile-workspace requirement.
