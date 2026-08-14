---
epic: M1-E13
type: epic
title: Make Restricted Execution the Default
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e13
depends_on: [M1-E02, M1-E05]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E13: Make Restricted Execution the Default

## Goal

Make the safe local execution profile the default coding mode.

## Scope

- Define the restricted execution profile as the default coding profile.
- Require an explicit profile choice for any less restricted mode.
- Require each restricted operation to declare an explicit environment allowlist.
- Require each restricted operation to declare workspace, toolchain, artifact, and temporary roots.
- Record the effective profile before work starts.
- Report when a requested operation is outside the restricted profile.
- Keep trusted-workspace mode as an explicit option only.
- Label trusted-workspace mode as not a sandbox and exclude it from the restricted-execution gate.

## Out of Scope

- File and symbolic-link enforcement.
- Network enforcement.
- Child-process tree ownership.
- Environment materialization and private temporary `HOME` from M1-E14.
- Remote, managed, container, or general executor adapters.

## Dependencies

This epic depends on M1-E02 for the Jido home roots and M1-E05 for the approved Jidoka execution contract.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request defines the profile contract, default selection, effective-profile record, and trusted-workspace warning. It must not claim that later boundary controls are complete.

## Acceptance Checks

- A coding run uses restricted execution when the user does not select another profile.
- A less restricted profile cannot become active without an explicit user choice.
- Every restricted operation request contains an explicit environment declaration and root set.
- The effective profile is visible before work starts and is present in the run record.
- Trusted-workspace mode is clearly labelled as not a sandbox.
- The restricted profile does not pass until the required boundary adapters report their enforcement contract.

## Proof Artifacts

- Versioned restricted-profile definition.
- Default-selection and explicit-profile test results.
- Effective-profile display and run-record result.
- Trusted-workspace warning result.
- Jidoka policy-contract compatibility result.

## Milestone Traceability

This epic covers the Milestone 1 requirement to make restricted execution the default coding mode and to keep trusted-workspace mode explicit and outside the sandbox claim.
