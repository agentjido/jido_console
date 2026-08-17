---
epic: M3-E36
type: epic
title: Prove the v0.3 Production Candidate
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e36
depends_on: [M3-E34, M3-E35]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E36: Prove the v0.3 Production Candidate

## Goal

Build and prove one immutable v0.3 artifact through the complete durable-continuity and common release gates.

## Scope

- Freeze the exact source, roadmap, imported Beadwork graph, Jidoka, SQLite
  adapter, schema, fixtures, toolchain, support claim, and qualification profile.
- Build one native production payload from a clean checkout.
- Wrap the same payload in every claimed platform and channel candidate.
- Install, start, update, and remove each claimed candidate.
- Run all earlier release workflows plus the M3-E33 continuity, M3-E34 crash, and M3-E35 compatibility proofs through the installed artifact.
- Run backup, migration, restore, physical repair, semantic repair, retry, fork, archive, removal, sensitive-admission, credential-profile, and isolated-home workflows.
- Record checksums, SBOM, provenance, limits, support matrix, known limits, security boundary, and repair path.
- Record publication as skipped and perform no tag, upload, or package publication.

## Out of Scope

- Product, fixture, oracle, or packaging fixes
- A new support claim
- Publication, tag, release, upload, Homebrew publish, or npm publish
- Changing the candidate after evidence starts

## Dependencies

This epic depends on M3-E34, M3-E35. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E34 and M3-E35 pass against one source.
- The working tree is clean and all dependencies are locked.
- No critical defect invalidates the v0.3 claim.
- Publication remains disabled.

### Decisions and invariants

- Freeze one candidate manifest before evidence starts. Any source, dependency, schema, artifact, fixture, or support change discards the candidate.
- Tests run the installed artifact, not a development checkout.
- All channel candidates wrap the same native payload checksum.
- A failed behavior returns to its owning epic and requires a new candidate.
- Local candidate files are evidence only and are not published.

### Delivery steps

1. Freeze the candidate manifest and all identities.
2. Build the native payload and channel candidates from a clean checkout.
3. Record checksums, SBOM, provenance, sizes, and wrapper relationships.
4. Run platform and channel install, start, update, and remove checks.
5. Run all earlier workflows and the complete durable workflow.
6. Rerun crash, compatibility, capacity, performance, and secret proofs.
7. Verify quick start, support matrix, known limits, security boundary, backup, repair, and removal guidance.
8. Record a passing or blocked candidate result and skipped publication.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Candidate identity | One source, roadmap, Jidoka, schema, and payload | Exact checksums everywhere |
| Installed durable workflow | Admission through restart, resume, repair, retry, fork, and archive passes | Isolated Jido home |
| Crash and compatibility | M3-E34 and M3-E35 pass through artifact | Same fixtures and seeds |
| Limits and secrets | Qualification profile passes; zero declared canaries in Jido-owned durable and fixture output data | All file and output classes |
| Publication | No tag, release, upload, or publish action | Before and after inventory |

### Completion boundary and handoff

M3-E37 receives this immutable candidate and evidence. It cannot repair or retest missing product behavior.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- One immutable artifact satisfies every v0.3 claim.
- Every claimed channel uses the same native payload.
- Install, start, update, remove, earlier workflows, and durable workflows pass through the artifact.
- Crash, reconciliation, compatibility, backup, restore, repair, retention, archive, and removal proofs pass.
- All count, byte, queue, file, recovery, and candidate timing targets pass.
- Secret scans find zero declared credential-canary values in Jido-owned durable
  and fixture output data, and credential-specific product fields accept only
  profile and reference identities.
- Support, limits, security, and repair documentation names the exact candidate.
- No development checkout result replaces artifact evidence.
- No publication action occurs.

## Proof Artifacts

- Exact v0.3 candidate manifest
- Imported Beadwork graph identity and roadmap link
- Production artifact and checksum set
- SBOM and provenance
- Platform-by-channel results
- Installed durable workflow
- Crash and compatibility reruns
- Qualification measurements and secret scan
- Quick-start, support, limit, security, and repair review
- Skipped-publication record

## Milestone Traceability

This epic proves the v0.3 source-quality candidate without publishing it.
