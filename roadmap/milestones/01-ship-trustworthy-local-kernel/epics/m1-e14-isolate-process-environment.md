---
epic: M1-E14
type: epic
title: Isolate the Restricted Process Environment
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e14
depends_on: [M1-E08, M1-E13]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E14: Isolate the Restricted Process Environment

## Goal

Run restricted work with only the declared environment, credentials, and temporary home.

## Scope

- Build an explicit environment allowlist for each restricted operation.
- Pass only declared credential references to the restricted process.
- Use a private temporary `HOME` for restricted work.
- Keep provider credential values out of process arguments and inherited undeclared variables.
- Keep temporary files under declared Jido home or execution roots.
- Record the environment and credential policy without recording secret values.
- Reject an incomplete or invalid environment contract before the turn starts.

## Out of Scope

- File-root and symbolic-link checks.
- Network policy enforcement.
- Child-process tree cleanup.
- Credential storage or provider support claims.

## Dependencies

This epic depends on M1-E08 for declared credential sources and M1-E13 for the restricted profile contract.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds process-environment construction, private temporary `HOME`, credential allowlisting, and redacted evidence.

## Acceptance Checks

- Restricted processes receive only the declared environment keys.
- A restricted process uses a private temporary `HOME` and cannot use the operator home by default.
- Credential values do not appear in arguments, configuration, events, logs, traces, artifacts, or session data.
- Undeclared credential sources are rejected before a turn starts.
- An invalid or incomplete environment contract fails closed.
- Evidence identifies the effective keys and paths without exposing values or private paths.

## Proof Artifacts

- Restricted environment manifest.
- Private `HOME` isolation result.
- Credential allowlist and redaction result.
- Invalid-contract denial results.
- Environment evidence record with no secret values.

## Milestone Traceability

This epic covers the Milestone 1 requirement for an explicit environment allowlist and private temporary `HOME` in the restricted coding path.
