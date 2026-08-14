---
epic: G0-E06
type: epic
title: Add hostile file-boundary fixtures
status: proposed
milestone: gate-0
beadwork_id: jido_console-g0e06
depends_on: [G0-E01, G0-E13]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.5
---

# G0-E06: Add Hostile File-Boundary Fixtures

## Goal

Create controlled fixtures that show the current file-access boundary and its known risks.

## Scope

- Add a canary-secret fixture that never uses a real credential.
- Add an undeclared file-access fixture outside the selected workspace.
- Add symbolic-link escape cases for files and directories.
- Run each case in an isolated temporary workspace.
- Classify each result as denied, known risk, or not applicable.
- Link each known risk to the Milestone 1 control that must close it.

## Out of Scope

- The network and child-process cases from G0-E07
- Restricted-execution implementation
- Real home-directory data or credentials
- A claim that trusted-workspace mode is a sandbox

## Dependencies

This epic depends on G0-E01 for the evidence result contract and G0-E13 for the Milestone 1 control links.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the file-boundary fixtures, runner, result classes, and focused tests.

## Acceptance Checks

- Fixtures use only controlled targets. They record denied, known-risk, or not-applicable results. A known-risk result records only a digest and the required Milestone 1 control.
- Reports use canary digests and never include canary contents.
- Each case has one explicit expected result class.
- The runner detects an unexpected access result and fails with a clear reason.
- Repeated runs start from the same fixture state.
- Each known risk links to planned Milestone 1 work.

## Proof Artifacts

- File-boundary fixture manifest
- Redacted result for each case
- Isolation and cleanup result
- Milestone 1 risk links

## Milestone Traceability

This epic covers secret access, undeclared file access, and symbolic-link escape in the Gate 0 hostile-workspace requirement.
