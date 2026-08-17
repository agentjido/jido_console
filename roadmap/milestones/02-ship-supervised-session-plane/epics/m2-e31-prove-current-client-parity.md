---
epic: M2-E31
type: epic
title: Prove Current-Client Parity
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e31
depends_on: [M2-E27, M2-E28, M2-E29, M2-E30]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E31: Prove Current-Client Parity

## Goal

Prove through the real production entry points that the TUI, automation, text,
and JSON clients observe the same ordered session behavior.

## Scope

- Run one provider-free fixture corpus through each production client path.
- Run the reusable M2-E26 contract rules through production drivers.
- Compare ordered semantic outcomes before renderer-specific formatting.
- Prove attach, normal output, acknowledgement, gap recovery, detach, and error behavior.
- Prove automation compatibility for schemas, artifacts, output, and exit status.
- Verify that renderer-specific work cannot change semantic session state.
- Fail if a production client consumes a raw Jidoka or runtime-event path.
- Record a reproducible parity report and normalized outcome ledger.

## Out of Scope

- Product behavior changes
- Fixes for TUI, automation, text, JSON, delivery, recovery, or client-contract defects
- New clients or new client features
- Removal of isolated legacy files
- A production release candidate or release audit
- Live provider access

## Dependencies

This epic depends on M2-E27, M2-E28, M2-E29, and M2-E30 because all current
clients must have a production `Session.Client` path before parity can be
proved.

## Pull Request Boundary

Deliver this epic in exactly one proof-only pull request. The pull request can
add fixtures, a shared test harness, boundary checks, and evidence. It cannot
change production behavior. A product defect must return to its owning epic
before this proof can pass.

## Detailed Delivery Plan

### Preconditions

- M2-E27 runs the production TUI only through `Session.Client`.
- M2-E28 runs automation through the production command path and approved Jidoka engine or replay path.
- M2-E29 exposes a public production text projection over canonical client output.
- M2-E30 exposes a public production JSON projection over canonical client output.
- The M2-E26 reusable contract suite passes for each production driver.
- M2-E17 and M2-E18 bounds and recovery rules are stable.

If a production entry point or required behavior is absent, stop this epic and
return the defect to M2-E17, M2-E18, M2-E26, or M2-E27 through M2-E30. Do not
implement the missing behavior in M2-E31.

### Decisions and invariants

Use one versioned, provider-free fixture corpus. It must include fixed time,
fixed identities, bounded content, deterministic tool effects, permissions,
control results, and recovery data. All clients use the same fixture source.

Run each path through its production boundary:

| Client | Required production boundary |
| --- | --- |
| TUI | Public Console or TUI entry point with a deterministic terminal adapter |
| Automation | Public `run` and `eval` command paths with the approved Jidoka engine or release replay |
| Text | Public text adapter over canonical `Session.Client` output |
| JSON | Public JSON adapter over canonical `Session.Client` output |

Observation helpers and direct session snapshots cannot count as production
parity proof.

Normalize each run to one semantic ledger before client formatting. Each ledger
entry contains the protocol version, session, request, run, step, permission,
and source identities that apply; canonical sequence and type; bounded semantic
payload; outcome; and visible side effects. Remove only approved nondeterminism,
such as injected fixture time and generated attachment identity. Do not remove
meaningful order, error, permission, control, or terminal data.

Parity means that all clients produce the same ordered semantic ledger and
side-effect ledger. Renderer bytes can differ. Text layout, JSON encoding, ANSI,
cursor movement, and terminal timing cannot change the semantic result.

Automation proof must also compare its documented schema, artifact names and
content, standard output, standard error, and exit status. A live-provider
sentinel must fail the suite if a fixture tries to access a provider.

Add a source and syntax boundary check. It rejects raw Jidoka or runtime-event
consumption in production client code and rejects use of observation helpers as
parity evidence. It allows only the approved internal Jidoka ingress in the
session owner.

### Delivery steps

1. Define the versioned provider-free fixture corpus and stable identity and time inputs.
2. Add one shared runner that records canonical outputs and side effects.
3. Add one normalizer and ordered semantic fingerprint.
4. Run the TUI through its real entry point with a deterministic terminal.
5. Run automation through public `run` and `eval` entry points.
6. Run text through its public production projection.
7. Run JSON through its public production projection.
8. Add lifecycle, error, cancellation, gap, stale, and cross-session cases.
9. Compare the ordered semantic and side-effect ledgers for all four clients.
10. Compare automation schema, artifact, stream, and exit-status compatibility.
11. Add the raw-path and proof-path boundary check with a deliberate failure fixture.
12. Record the production path matrix, outcome ledger, and parity report.

### Expected file plan

- One versioned fixture under `test/fixtures/session/`
- One shared parity harness under `test/support/`
- Production-path parity tests for TUI, automation, text, and JSON
- One source and syntax boundary test
- `roadmap/milestones/02-ship-supervised-session-plane/proof/current-client-parity.md`

No file under `lib/` can change in this epic.

### Test and evidence matrix

| Case | Oracle | Bound or guard |
| --- | --- | --- |
| Attach | Same initial semantic state | Bounded M2-E18 snapshot |
| Normal model and tool output | Same ordered ledger | M2-E17 batch and byte limits |
| Permission and control | Same exact identities and outcome | No renderer authority |
| Success, failure, cancellation, hibernation | Same single terminal outcome | No duplicate terminal result |
| Duplicate output | Same no-op or typed failure | Sequence does not advance twice |
| Stale or cross-session output | Same typed rejection | State remains unchanged |
| Gap and recovery | Same snapshot, suffix, and resume point | M2-E18 count and byte limits |
| TUI detach and reattach | Work continues; state restores | Renderer-local state stays local |
| Renderer isolation | Semantic and side-effect ledgers stay equal | Formatting cannot change state |
| Automation compatibility | Documented schemas, artifacts, streams, and status match | No live provider access |
| Raw-path scan | No production client bypass | Approved session-owner ingress only |
| Proof-path scan | No observation helper used as the oracle | Real entry point required |

### Completion boundary and handoff

M2-E31 is complete when the same corpus passes through all four production
entry points, the ordered ledgers and side effects match, automation remains
compatible, the raw-path guard passes, and the evidence identifies the exact
source and fixture version.

M2-E32 receives the passing suite unchanged and uses it only to prove that
legacy deletion did not change behavior. M2-E31 does not correct product code.
Any failure returns to the epic that owns the behavior.

### Risks and controls

- A snapshot-only test can hide stream defects. Require the production live-output path.
- Display-byte comparison can create false results. Compare canonical semantic ledgers first.
- Random identities and clocks can make proof unstable. Inject and record deterministic values.
- Automation cancellation can race. Use a controlled provider-free cancellation point.
- A fake engine can bypass production automation. Require the approved engine or release-replay boundary.
- A broad scan can reject valid server ingress. Use an exact allowlist for the internal owner boundary.

## Acceptance Checks

- One versioned fixture corpus runs through every current production client.
- Every run uses the production entry point and canonical `Session.Client` output.
- Each client observes the same ordered outcomes, identities, and visible side effects.
- Attach, output, acknowledgement, gap recovery, detach, and errors match the contract.
- Renderer-specific work does not change session state or semantic outcomes.
- Automation schemas, artifacts, output streams, and exit status remain compatible.
- Duplicate, stale, cross-session, and invalid recovery cases have the same result.
- No fixture accesses a live provider.
- No production client consumes raw Jidoka or runtime-event data.
- No observation helper or direct snapshot is used as the production-path oracle.
- No production behavior file changes in this epic.

## Proof Artifacts

- Current-client production path matrix
- Versioned provider-free fixture corpus
- Normalized ordered outcome and side-effect ledger
- TUI production-entry result
- Automation compatibility result
- Text and JSON projection results
- Lifecycle, cancellation, and recovery results
- Raw-path and proof-path boundary results
- Current-client parity report

## Milestone Traceability

This epic supplies proof-only client parity after all production client
migrations. It does not qualify a production artifact or change client
behavior.
