---
epic: M2-E36
type: epic
title: Requalify the v0.2 Production Candidate After Closeout
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e36
depends_on: [M2-E32]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.2.0
last_updated_in: 1.2.0
---

# M2-E36: Requalify the v0.2 Production Candidate After Closeout

## Goal

Build and prove one exact v0.2 production candidate that contains all
Milestone 2 closeout work.

## Scope

- Freeze the exact source, Jidoka revision, roadmap version, and support claim.
- Build one new production artifact from a clean checkout.
- Run the complete common release gate against that exact artifact.
- Test every claimed platform and channel with the same native payload.
- Rerun earlier release workflows and compatibility fixtures against the artifact.
- Prove the M2-E17 receiver mailbox and copied-payload bounds through the artifact.
- Prove M2-E18 gap recovery and ordinary incremental updates through the artifact.
- Prove client detach, reattach, failure, cancellation, worker drain, and cleanup.
- Rerun the M2-E31 production parity suite and the M2-E32 raw-path guard.
- Record checksums, provenance, support results, known limits, and repair steps.
- State the pre-Milestone-3 application-crash loss limit.

## Out of Scope

- Product code or behavior changes
- A new platform, channel, provider, model, or client claim
- Application-restart recovery or a durable input receipt
- Production publication
- A release decision or evidence audit
- Changes to the historical M2-E33 or M2-E34 evidence

## Dependencies

This epic depends on M2-E32 because the candidate must contain all closeout
implementation, production parity, and legacy-path deletion work.

M2-E33 is historical candidate evidence for an earlier source. It is not a
dependency and does not qualify this candidate.

## Pull Request Boundary

Deliver this epic in exactly one candidate-and-evidence pull request. It builds
and proves one immutable candidate. It cannot fix product behavior, expand the
support claim, publish v0.2, or change the candidate after evidence starts.

## Detailed Delivery Plan

### Preconditions

- M2-E09, M2-E17, M2-E18, M2-E26, M2-E27, M2-E31, and M2-E32 are complete.
- M2-E28, M2-E29, and M2-E30 production client paths still pass M2-E31.
- The working tree is clean and every dependency is locked.
- The support matrix and packaging channels are unchanged unless a separate roadmap change approves them.
- No critical defect is open against the Milestone 2 claim.

If a product or packaging defect appears, stop the proof and return it to its
owning epic or a new roadmap epic. Do not fix it in M2-E36.

### Decisions and invariants

Freeze one candidate manifest before testing. It contains:

- Exact source commit and repository state
- Exact roadmap version
- Exact Elixir, Erlang/OTP, Mix, and build-tool versions
- Exact Jidoka and other dependency identities
- Native payload checksum and size
- Wrapper or channel package checksums
- Claimed platform, architecture, and channel cells
- Fixture and proof-suite identities
- Build time and build environment identity

All channel candidates must wrap the same tested native payload. If any source,
dependency, build input, artifact byte, or support claim changes, discard the
evidence and start a new candidate.

Tests must install and run the artifact as a user receives it. A development
checkout result can support diagnosis but cannot qualify the candidate.

The receiver-bound proof must stop one attached client from reading. Measure
its `message_queue_len`, the size and count of copied messages, the server-owned
queued item and byte counts, and the one in-flight batch bound. Use the named
M2-E17 limits and hold the condition longer than the acknowledgement timeout.

The recovery proof must cause a real gap, recover through snapshot and suffix,
resume at the exact next sequence, and compare the client state with the session
owner. A separate ordinary-output case must prove that normal updates are
incremental and do not send repeated full snapshots.

The raw-path proof uses the final M2-E32 guard and the installed artifact. The
only approved raw Jidoka path is the internal runtime ingress into the session
owner.

### Delivery steps

1. Freeze and record the source, toolchain, dependency, roadmap, fixture, and support identities.
2. Build the native production payload from a clean checkout.
3. Create each claimed channel candidate around the same payload.
4. Record checksums, sizes, provenance, and the candidate manifest.
5. Install, start, update, and remove each claimed platform-channel cell.
6. Run all earlier candidate workflows and compatibility fixtures.
7. Run the complete supervised-session workflow through the artifact.
8. Measure the stopped-receiver mailbox, copied-payload, queue, and in-flight bounds.
9. Prove incremental normal output, explicit gap, snapshot, suffix, and exact resume.
10. Prove detach, reattach, failure, cancellation, drain, and cleanup.
11. Rerun M2-E31 parity and M2-E32 raw-path proof through the candidate.
12. Verify the quick start, support matrix, limits, security boundary, and repair path.
13. Record a pass or blocked candidate result without publication.

### Expected file plan

- Production artifact and channel candidates in the normal release output location
- One immutable candidate manifest and checksum set
- Platform-by-channel acceptance records
- `roadmap/milestones/02-ship-supervised-session-plane/proof/v0-2-closeout-candidate.md`
- Current quick start, support matrix, known-limit, security, and repair references

No product source file can change in this epic.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Clean build | Reproducible production artifact | Exact source, toolchain, and dependency manifest |
| Platform and channel | Install, start, update, remove | Same native payload checksum |
| Earlier workflows | All prior compatibility fixtures pass | Exact candidate path, not checkout |
| Supervised session | All current clients use one owner and protocol | Exact session and attachment identities |
| Stopped receiver | No unbounded mailbox or copied payload growth | M2-E17 named count, byte, batch, and timeout limits |
| Normal output | Ordered incremental semantic batches | No repeated full snapshot |
| Gap recovery | Snapshot plus suffix equals owner state | M2-E18 count, byte, version, and sequence limits |
| Detach and reattach | Work continues and state restores | Exact session; new attachment identity |
| Failure and cancellation | One typed outcome and exact drain | No orphan owned worker |
| Client parity | M2-E31 ledgers and side effects match | Same fixture and oracle version |
| Raw-path guard | No client runtime bypass | Approved owner ingress only |
| Documentation | Complete workflow is runnable | Candidate checksum and support cell named |

### Completion boundary and handoff

M2-E36 is complete when one exact artifact passes every claimed platform and
channel cell, all common and Milestone 2 gates pass through that artifact, and
the candidate manifest links every result to the same source and payload.

M2-E37 receives the immutable candidate, manifest, checksums, and evidence.
M2-E36 does not decide publication or correct a failed product behavior.

### Risks and controls

- Evidence can mix two payloads. Require one native checksum in every channel record.
- A checkout test can replace artifact proof. Record the executable and package path for each result.
- A bound can measure only sender state. Measure the receiver mailbox and copied payload too.
- Recovery can hide full-snapshot polling. Add an independent ordinary incremental-output trace.
- A late change can invalidate proof. Freeze the manifest and restart on any identity change.

## Acceptance Checks

- One clean-checkout candidate has exact source, dependency, toolchain, and roadmap identities.
- Every claimed platform-channel cell uses the same tested native payload.
- Install, start, update, and remove pass for every claimed cell.
- Earlier workflows and compatibility fixtures pass through the artifact.
- The stopped receiver stays inside every named M2-E17 bound.
- Ordinary output is incremental and a real M2-E18 gap recovers correctly.
- Detach, reattach, failure, cancellation, drain, and cleanup pass through the artifact.
- M2-E31 parity and M2-E32 raw-path proof pass unchanged.
- The quick start, support matrix, known limits, security boundary, and repair path are current.
- Evidence states the application-crash loss limit before Milestone 3.
- No product code or publication action is part of the pull request.

## Proof Artifacts

- Exact post-closeout candidate manifest
- Production artifact and checksum set
- Platform-by-channel acceptance results
- Stopped-receiver mailbox and copied-payload measurements
- Incremental-output and gap-recovery traces
- Detach, reattach, failure, cancellation, drain, and cleanup evidence
- M2-E31 parity and M2-E32 raw-path reruns
- Quick-start and support-document review

## Milestone Traceability

This epic supersedes M2-E33 as candidate evidence for the final Milestone 2
source. M2-E33 remains an unchanged historical record.
