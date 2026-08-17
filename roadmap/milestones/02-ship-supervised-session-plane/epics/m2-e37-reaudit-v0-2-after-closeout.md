---
epic: M2-E37
type: epic
title: Reaudit v0.2 After Milestone 2 Closeout
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e37
depends_on: [M2-E36]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.2.0
last_updated_in: 1.2.0
---

# M2-E37: Reaudit v0.2 After Milestone 2 Closeout

## Goal

Make the final evidence-only quality decision for the exact post-closeout v0.2
source and production candidate.

## Scope

- Audit the final evidence for M2-E01 through M2-E32 and M2-E36.
- Verify the exact source, roadmap, Jidoka, payload, package, and checksum identities.
- Verify all common release-gate and Milestone 2 exit-gate results.
- Verify stopped-receiver bounds, incremental output, recovery, parity, and raw-path removal evidence.
- Record unresolved defects, support claims, known limits, and the crash-loss limit.
- Reaffirm that v0.2 publication remains intentionally skipped.
- Declare the exact approved Milestone 3 planning and implementation baseline.
- Keep M2-E33 and M2-E34 as superseded historical evidence.

## Out of Scope

- Product, test-oracle, packaging, or candidate changes
- New evidence generated from a development checkout
- A new platform, channel, provider, model, or client claim
- Publication, tagging, archive upload, Homebrew publication, or npm publication
- Reopening or rewriting M2-E33, M2-E34, or M2-E35
- Milestone 3 design or implementation

## Dependencies

This epic depends on M2-E36 because the final audit must review one immutable
post-closeout candidate and its complete evidence.

M2-E33 and M2-E34 remain closed historical records. M2-E35 remains the closed
record of the no-publication decision. They are not reused as proof for the new
source.

## Pull Request Boundary

Deliver this epic in exactly one audit-only pull request. It records identities,
evidence links, findings, and the quality decision. It cannot change the
candidate, generate missing product proof, publish v0.2, or plan Milestone 3.

## Detailed Delivery Plan

### Preconditions

- M2-E36 has one immutable passing candidate or one explicit blocked result.
- The candidate manifest names every source, dependency, toolchain, artifact, and support identity.
- Every required proof is stored in a stable location and names the exact candidate.
- The Beadwork graph and roadmap dependency graph agree.
- Publication remains disabled.

If evidence is absent, mixed, stale, or tied to another payload, record the
audit as blocked. Do not replace missing evidence in M2-E37.

### Decisions and invariants

The audit uses one evidence index. Each row names:

- Epic and acceptance claim
- Evidence file or record
- Exact source commit
- Exact native payload checksum
- Platform and channel, when applicable
- Fixture, test, or proof version
- Result and review status
- Known limit or defect link

M2-E33 and M2-E34 can be linked only as historical context. They cannot satisfy
a final-source evidence row. M2-E35 supplies the prior no-publication decision;
this audit must reaffirm that the decision still applies.

The audit must trace all M2-E01 through M2-E32 requirements. Closed early epics
can use their original evidence when the requirement and evidence remain valid.
Any requirement affected by the closeout source must use M2-E36 evidence tied to
the final candidate.

The final decision has only two results:

- `approved`: all required evidence matches one source and payload, no critical defect invalidates the claim, publication remains skipped, and the exact source is the Milestone 3 baseline.
- `blocked`: at least one required claim lacks valid evidence or a critical defect invalidates the claim.

An approved audit does not authorize publication.

### Delivery steps

1. Freeze the audit input manifest from M2-E36.
2. Build the complete M2-E01 through M2-E32 and M2-E36 evidence index.
3. Verify each source, dependency, toolchain, payload, package, and checksum identity.
4. Verify every common release-gate result.
5. Verify every Milestone 2 exit-gate result.
6. Review the receiver-bound, incremental-output, recovery, parity, and raw-path evidence in detail.
7. Review support claims, known limits, security boundary, and repair path.
8. Confirm the application-crash loss statement and absence of a durable-receipt claim.
9. Reaffirm that publication is skipped and no publication artifact exists.
10. Record unresolved defects and make the approved or blocked decision.
11. If approved, name the exact source commit and roadmap version as the Milestone 3 baseline.
12. Link the final audit to the roadmap and Beadwork graph.

### Expected file plan

- `roadmap/milestones/02-ship-supervised-session-plane/proof/v0-2-closeout-audit.md`
- One complete evidence index in that audit record or a linked immutable file
- Roadmap and Beadwork links to the final decision

No product, packaging, fixture, or proof-generation file can change in this
epic.

### Test and evidence matrix

| Audit area | Required result |
| --- | --- |
| Source and roadmap | Exact final commit and roadmap version agree |
| Dependencies and toolchain | Exact identities match the candidate manifest |
| Native payload and channel packages | Checksums and wrapper relationships agree |
| Platform-channel support | Every claimed cell has exact candidate proof |
| Earlier epic claims | M2-E01 through M2-E32 have valid linked evidence |
| Receiver bounds | Mailbox and copied payload are both measured and pass |
| Normal output and recovery | Incremental trace and exact gap recovery pass |
| Client parity and raw-path removal | M2-E31 and M2-E32 final-source evidence passes |
| Common release gate | Every item passes through the production artifact |
| Known limits | Crash-loss and support limits are explicit |
| Publication | Still skipped; no tag or package was published |
| Baseline | One exact source and roadmap version are named for Milestone 3 |

### Completion boundary and handoff

M2-E37 is complete when the audit records an approved or blocked result for one
exact source and payload. An approved result closes Milestone 2 and names the
only baseline that Milestone 3 planning can use.

The M3 planning-readiness task can start only after an approved M2-E37 result.
M2-E37 does not create Milestone 3 epics or change the candidate.

### Risks and controls

- Historical evidence can be mistaken for final proof. Mark M2-E33 and M2-E34 as superseded for the final source.
- A checksum can identify a wrapper but not its native payload. Record both and verify the relationship.
- An audit can hide missing proof by rerunning tests. Mark the audit blocked and return the gap to M2-E36.
- A quality approval can be read as publication approval. State the no-publication decision in the result.
- Milestone 3 can start from a moving branch. Name one exact commit and roadmap version.

## Acceptance Checks

- One evidence index covers M2-E01 through M2-E32 and M2-E36.
- Every final-source claim names the same source commit and native payload checksum.
- Platform and channel evidence matches the candidate manifest.
- The common release gate and every Milestone 2 exit gate are reviewed.
- Receiver bounds, incremental output, recovery, parity, and raw-path evidence pass.
- Known limits, unresolved defects, and the application-crash loss limit are explicit.
- M2-E33 and M2-E34 are marked as historical evidence superseded for the final source.
- M2-E35 remains unchanged and publication is explicitly skipped again.
- The audit contains an approved or blocked decision.
- An approved decision names the exact Milestone 3 baseline.
- No candidate, product, packaging, or publication change occurs in this epic.

## Proof Artifacts

- Final v0.2 closeout audit record
- Exact source, roadmap, dependency, toolchain, and payload identity record
- Complete Milestone 2 evidence index
- Common and milestone exit-gate review
- Known-limit and unresolved-defect record
- Reaffirmed no-publication decision
- Exact Milestone 3 baseline declaration

## Milestone Traceability

This epic supersedes M2-E34 as the final audit for the post-closeout Milestone 2
source. M2-E34 remains an unchanged historical record.
