---
epic: M3-E37
type: epic
title: Audit the v0.3 Source Milestone
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e37
depends_on: [M3-E36]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E37: Audit the v0.3 Source Milestone

## Goal

Make the final evidence-only quality decision for the exact v0.3 source and production candidate.

## Scope

- Audit every M3-E01 through M3-E36 acceptance claim and proof artifact.
- Verify source, roadmap, Jidoka, SQLite adapter, schema, migration, fixture, toolchain, payload, wrapper, and checksum identities.
- Verify the common release gate and every Milestone 3 exit gate.
- Verify the exact imported Milestone 3 Beadwork graph, roadmap links, and epic
  dependency identities used by the candidate.
- Verify durable acknowledgement, generation fencing, watermark, orphan, unsafe-effect, resume, fork, client, limit, security, backup, repair, retention, and compatibility evidence.
- Record unresolved defects, known limits, support claims, security limits, repair guidance, and critical-defect status.
- Record an approved or blocked decision.
- Reaffirm skipped publication and name the exact Milestone 4 baseline when approved.

## Out of Scope

- Product, test, fixture, schema, candidate, or packaging changes
- Generating missing evidence
- Publication, tagging, uploading, or package release
- Milestone 4 implementation

## Dependencies

This epic depends on M3-E36. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E36 provides one immutable passing candidate or one explicit blocked result.
- The imported M3-E01 through M3-E37 Beadwork graph exists, passed the x5b graph
  check before implementation, and matches the roadmap dependency graph.
- Every evidence item names the same source and payload.
- Publication remains disabled.

### Decisions and invariants

- The audit uses one evidence index. Each row names the epic, claim, evidence path, source, payload, schema, fixture, platform, result, reviewer, and known limit.
- Missing, mixed, stale, or development-checkout evidence makes the decision blocked.
- An approved source-quality decision does not authorize publication.
- Only an approved audit names the Milestone 4 baseline.
- The audit does not rerun a failed test to hide the original result.

### Delivery steps

1. Freeze the M3-E36 manifest as the audit input.
2. Build the complete M3-E01 through M3-E36 evidence index.
3. Verify all source, dependency, schema, fixture, package, and payload identities.
4. Review every common and Milestone 3 exit gate.
5. Review storage limits, crash windows, orphan cases, unsafe effects, recovery modes, client paths, security, and compatibility.
6. Review known limits, repair guidance, critical defects, and publication state.
7. Record approved or blocked and, if approved, the exact Milestone 4 baseline.
8. Link the decision to the roadmap and the already-imported verified Beadwork graph.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Evidence coverage | Every epic and gate has exact proof | One source and payload |
| Durability | Acknowledgement, watermark, crash, and generation claims pass | Declared limits and seeds |
| Continuity | Exact, transcript-only, repair, retry, fork, and client claims pass | No unsafe repeat |
| Security and lifecycle | Sensitive admission, credential profiles, paths, backup, restore, archive, and removal pass | File-only Jido-owned durable boundary |
| Decision | Approved or blocked with reviewer and defects | Publication remains skipped |

### Completion boundary and handoff

An approved M3-E37 result closes Milestone 3 and supplies the only source baseline for Milestone 4 planning and implementation.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- One evidence index covers M3-E01 through M3-E36.
- Every final claim names the same source commit, roadmap version, Jidoka pin, storage schema, and native payload.
- The common release gate and every Milestone 3 exit gate are reviewed.
- The roadmap, all generated epic records, and the imported Beadwork graph have
  exact bidirectional links and matching dependencies.
- All durable, crash, orphan, uncertainty, recovery, client, limit, security, lifecycle, and compatibility claims have exact evidence.
- Known limits, unresolved defects, repair guidance, and critical-defect status are explicit.
- The audit result is approved or blocked.
- An approved result names one exact Milestone 4 baseline.
- Publication is explicitly skipped and no candidate or product change occurs.

## Proof Artifacts

- Complete Milestone 3 evidence index
- Exact source, roadmap, dependency, schema, fixture, and payload identity record
- Common and milestone exit-gate review
- Known-limit, security, and repair review
- Critical-defect assessment
- Approved or blocked v0.3 decision
- Skipped-publication and Milestone 4 baseline record

## Milestone Traceability

This epic closes the v0.3 source milestone with evidence only and no publication.
