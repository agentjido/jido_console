---
epic: M1-E15
type: epic
title: Enforce File and Symbolic-Link Boundaries
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e15
depends_on: [M1-E13, M1-E14]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E15: Enforce File and Symbolic-Link Boundaries

## Goal

Restrict file access to declared roots and fail safely on boundary escape attempts.

## Scope

- Restrict access to the declared workspace, toolchain, artifact, and temporary roots.
- Normalize and validate every path before access.
- Reject paths outside the declared roots.
- Reject symbolic-link escape for files and directories.
- Deny access to undeclared host files.
- Add a controlled canary secret and verify that its contents never leave the fixture.
- Record redacted enforcement evidence for allowed and denied operations.

## Out of Scope

- Network enforcement.
- Child-process tree ownership.
- Trusted-workspace behavior beyond its explicit warning.
- Real operator credentials or real host files in tests.

## Dependencies

This epic depends on M1-E13 for the restricted profile and M1-E14 for the isolated process environment.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request implements declared-root checks, symbolic-link checks, canary-secret denial, and deterministic hostile-boundary tests.

## Acceptance Checks

- Access inside each declared root succeeds when the operation is allowed.
- Access outside a declared root fails before the operation reaches the host file.
- File and directory symbolic-link escapes fail safely.
- A canary secret outside the declared roots cannot be read or disclosed.
- Path normalization cannot bypass the root check.
- Reports contain no canary contents, credential values, unstable process identifiers, or private host paths.
- The Gate 0 hostile file-boundary fixtures pass with the restricted adapter.

## Proof Artifacts

- Declared-root policy and path-normalization record.
- Allowed and denied file-operation results.
- Symbolic-link escape results.
- Redacted canary-secret result.
- Gate 0 hostile file-boundary report.

## Milestone Traceability

This epic covers the Milestone 1 requirement to restrict file access to declared roots, reject symbolic-link escape, and protect canary secrets.
