---
epic: M1-E28
type: epic
title: Prove the Golden Workflow Through the Production Artifact
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e28
depends_on: [M1-E10, M1-E11, M1-E12, M1-E15, M1-E16, M1-E17, M1-E18, M1-E19, M1-E20, M1-E22, M1-E27]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E28: Prove the Golden Workflow Through the Production Artifact

## Goal

Run the frozen Gate 0 coding task through the exact installed production
artifact and prove the complete restricted local workflow.

## Scope

- Run the frozen Gate 0 golden task through the production artifact.
- Use the exact installed artifact that represents the v0.1 release path.
- Run in restricted mode with the approved model, profile, and workspace.
- Record provider results when a provider call is available and use the approved
  recorded result when a provider call is not available.
- Prove repository discovery, read, search, edit, command, and test operations.
- Record the exact diff and the approval identity for each approved effect.
- Prove rejection leaves the workspace unchanged.
- Prove cancellation stops the current operation and leaves no owned process.
- Prove current-run patch revert restores the recorded pre-run state.
- Produce redacted manifests, transcripts, diffs, process results, and a short
  human-readable report.

## Out of Scope

- Changes to product behavior owned by another epic.
- Changes to the frozen Gate 0 task or its expected result.
- New provider support or a new execution profile.
- Publishing an artifact or making the final v0.1 release decision.
- Repairing a failed product control in this evidence PR.

## Dependencies

This epic depends on M1-E10, M1-E11, M1-E12, M1-E15, M1-E16, M1-E17, M1-E18,
M1-E19, M1-E20, M1-E22, and M1-E27. These epics provide the model and consent
controls, restricted execution, release artifact and channels, process and
workspace controls, and the frozen task evidence needed for this proof.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
production-artifact workflow runner, deterministic fixtures or recorded
provider inputs, proof assertions, redaction rules, and the first complete
report. It must not change product controls, add provider support, publish a
release, or include the final release decision owned by M1-E29.

## Acceptance Checks

- The runner uses the exact installed production artifact and records its
  version, digest, channel, and source identity.
- The frozen Gate 0 task runs in restricted mode with the declared model and
  profile.
- Repository discovery, read, search, edit, command, and test operations pass
  with recorded results.
- The report contains the exact normalized diff and the identity of each
  approved effect.
- A rejected effect leaves the workspace byte-for-byte unchanged.
- Cancellation stops the current run and leaves no owned child process.
- Current-run patch revert restores the recorded pre-run state.
- Provider output is recorded or the approved provider-free result is used.
- The evidence is redacted and contains no credential, private path, or
  unapproved environment value.
- The runner fails when a required proof step, restricted control, or cleanup
  check is missing.

## Proof Artifacts

- Production-artifact identity and digest record
- Golden-task run manifest
- Redacted provider result or recorded provider-free result
- Repository operation and exact-diff evidence
- Approval, rejection, cancellation, and revert evidence
- Child-process cleanup evidence
- Human-readable restricted-workflow report

## Milestone Traceability

This epic covers the Milestone 1 requirement to run the frozen golden task
through the production artifact and prove repository discovery, read, search,
edit, command, test, exact diff, approval, rejection, cancellation, and
current-run patch revert in restricted mode. It provides evidence for the
restricted golden-task, workspace-repair, and process-cleanup exit gates.
