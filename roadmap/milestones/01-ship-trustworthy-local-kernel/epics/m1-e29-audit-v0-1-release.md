---
epic: M1-E29
type: epic
title: Audit and Record the v0.1 Release Decision
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e29
depends_on: [M1-E01, M1-E02, M1-E03, M1-E04, M1-E05, M1-E06, M1-E07, M1-E08, M1-E09, M1-E10, M1-E11, M1-E12, M1-E13, M1-E14, M1-E15, M1-E16, M1-E17, M1-E18, M1-E19, M1-E20, M1-E21, M1-E22, M1-E23, M1-E24, M1-E25, M1-E26, M1-E27, M1-E28]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E29: Audit and Record the v0.1 Release Decision

## Goal

Record an evidence-only decision on whether Jido Console v0.1 passes every
Milestone 1 exit gate.

## Scope

- Review the evidence from M1-E01 through M1-E28.
- Check every declared v0.1 platform and channel cell for install, first run,
  update, and removal results.
- Check the clean-system first-run result without an existing Elixir or Erlang
  toolchain.
- Check that Homebrew, npm, and direct archive use the same native payload,
  version, license, checksums, and provenance.
- Check provider, offline-mode, model-picker, capability, and consent evidence.
- Check the approved immutable Jidoka compatibility evidence.
- Check restricted execution, workspace repair, credential isolation, boundary
  rejection, child-process cleanup, status, and shutdown evidence.
- Check the common milestone release gate in the roadmap index.
- Record the support matrix, quick-start and workflow evidence, known limits,
  security limits, repair guidance, critical-defect status, and final decision.
- Link each decision to its source epic, proof artifact, and recorded result.

## Out of Scope

- Product repair or implementation changes.
- New tests that change the acceptance contract.
- Provider, package, platform, or execution support changes.
- Publishing, uploading, tagging, or otherwise executing the release, which M1-E30 owns.
- Re-running a failed check to replace missing evidence without recording the
  original result.

## Dependencies

This epic depends explicitly on M1-E01 through M1-E28. The audit cannot make a
release decision until every prior Milestone 1 epic has a reviewed result and
linked proof artifact.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request contains only
the evidence index, exit-gate matrix, support matrix, quick-start and workflow
record, known-limits and security record, repair guidance, critical-defect
assessment, and the v0.1 release decision. It must not repair product behavior
or publish the release.

## Acceptance Checks

- Every M1-E01 through M1-E28 record has a source link, result, and proof
  artifact reference.
- Every Milestone 1 exit-gate statement has a pass, fail, or blocked result with
  its evidence location.
- All declared v0.1 platform and channel cells include install, first run,
  update, and removal results.
- The clean supported-system first-run result proves that no existing Elixir or
  Erlang toolchain is required.
- The three release channels show matching native payload identity, version,
  license, checksums, and provenance.
- Provider, offline-mode, model-support, consent, Jidoka, restricted-execution,
  boundary, process-cleanup, status, and shutdown results are present.
- The support matrix, quick-start and workflow record, known limits, security
  limits, and repair guidance are present and consistent with the evidence.
- The audit records whether any critical defect remains open.
- The final decision states pass, fail, or blocked and includes the decision
  date, evidence revision, and reviewer identity.
- The pull request does not modify product behavior or publish a release.

## Proof Artifacts

- Complete Milestone 1 evidence index
- Exit-gate decision matrix
- v0.1 platform and channel support matrix
- Quick-start and workflow evidence record
- Known-limits, security-limits, and repair guidance record
- Critical-defect assessment
- Signed or reviewable v0.1 release decision record

## Milestone Traceability

This epic covers the common milestone release gate and the final decision for
all Milestone 1 exit-gate checks. It closes the milestone only when the
evidence shows that the local kernel is trustworthy for the declared v0.1
scope. It does not claim durable session recovery or perform a release action.
