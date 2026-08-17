---
epic: M2-E18
type: epic
title: Recover Clients from Delivery Gaps
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e18
depends_on: [M2-E11, M2-E17]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E18: Recover Clients from Delivery Gaps

## Goal

Restore an attaching or gapped client to the session owner's exact semantic
state with a bounded snapshot, a contiguous event suffix, and an explicit
completion acknowledgement.

## Scope

- Define exact gap, snapshot, suffix, recovery, and completion data.
- Bind recovery to exact session, client, attachment, protocol, and gap identities.
- Use one bounded full snapshot for attach and explicit recovery only.
- Replay a bounded contiguous event suffix after the snapshot.
- Keep live delivery stopped until the client confirms that it applied all recovery data.
- Queue events created during recovery under the M2-E17 limits.
- Reset delivery only after identity, version, size, order, and sequence checks pass.
- Reject stale, repeated, future, cross-session, malformed, and oversized recovery data.
- Resume normal delivery with incremental canonical events.
- State clearly that this is process-lifetime recovery only.

## Out of Scope

- Application-restart recovery
- Durable input or delivery receipts
- A durable Console-to-Jidoka watermark
- Persistent event-log repair
- Lossy snapshot compaction
- Remote client deployment
- Multi-user collaboration

## Dependencies

This epic depends on M2-E11 for semantic replay and on M2-E17 for bounded
delivery, exact attachment identity, explicit gaps, and stopped live output.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds bounded
snapshot and suffix recovery, validation, recovery state transitions, and
focused proof. It must not add storage, restart recovery, or a final public
client behavior.

## Detailed Delivery Plan

### Preconditions

- M2-E11 can replay ordered canonical events into renderer-neutral state.
- M2-E17 produces a typed `delivery.gap` value and stops output for the exact attachment.
- The protocol provides fixed snapshot, suffix, list, map, and text bounds.
- Canonical history remains available in the live session owner for suffix selection.

### Decisions and invariants

Initial attach returns one bounded snapshot at owner sequence `S`. This
snapshot sets the initial delivery baseline. Events admitted after `S` enter
the bounded M2-E17 queue. The client applies the attach snapshot before it
pulls normal output. The readiness advisory contains no semantic payload, so
it cannot overtake the returned snapshot data.

Gap recovery uses this transaction:

1. **Begin recovery.** Validate the exact gap and attachment. Capture a snapshot at sequence `S`, issue a recovery token, and change delivery to `recovering`.
2. **Select suffix.** After the client applies the snapshot, return a contiguous suffix from `S + 1` through `T` and issue one completion token. Events after `T` stay queued.
3. **Complete recovery.** After the client applies the suffix, accept the exact completion token through `T`, remove queued events through `T`, change delivery to `open`, and make the next output ready.

No normal output is available while the attachment is `recovering`.

If queued event count or bytes exceed the M2-E17 limit during recovery, the
owner changes `recovering -> gapped`. It creates a new gap identity with reason
`recovery_queue_overflow`, invalidates every token from the old gap and
recovery transaction, clears queued recovery payload, retains the last
acknowledged sequence, records the current owner sequence, and makes one
readiness advisory available. The client must begin again from a new current
snapshot. A stale completion token cannot reopen delivery.

The snapshot contains only canonical data needed to restore semantic state:

- Session identity
- Protocol version
- Snapshot sequence
- Canonical history through the sequence
- Steering and follow-up queues
- Active run summary

Clients derive transcript, outcome, control, text, JSON, and renderer views.
The snapshot does not repeat these derived views. It contains no renderer
state, process value, runtime handle, delivery state, or client-local input.

The suffix contains:

- Exact session, client, and attachment identities
- Protocol version
- `after_sequence`
- `through_sequence`
- Ordered canonical event envelopes
- Recovery and completion token identities

The first event has sequence `after_sequence + 1`. The suffix has no gap,
duplicate, or reversed sequence. An empty suffix has equal `after_sequence`
and `through_sequence` values.

Use these maximum limits:

| Limit | Maximum value |
| --- | ---: |
| Encoded snapshot | 1,048,576 bytes |
| Events in one suffix | 1,000 |
| Encoded event suffix | 1,048,576 bytes |
| Queued live events during recovery | M2-E17 count limit |
| Queued live bytes during recovery | M2-E17 byte limit |
| Asynchronous semantic payload messages during recovery | 0 |

Do not truncate a snapshot or suffix. Return `snapshot_limit_exceeded` or
`recovery_window_exceeded`. The client must start again from a new current
snapshot.

Validation happens against temporary projection state. The client commits the
new projection only after the snapshot and suffix pass. A failed validation
does not change client projection state or server delivery state.

### Delivery steps

1. Add exact attachment, gap, recovery, suffix, and completion identities to the v1 `delivery` family.
2. Add required snapshot and suffix fields and their total encoded-size checks.
3. Regenerate Elixir and TypeScript protocol artifacts and examples.
4. Make the semantic snapshot contain one canonical history representation.
5. Add a validated restore boundary for the canonical snapshot state.
6. Add pure snapshot, suffix selection, validation, and application functions.
7. Add `recovering` delivery state and exact transaction tokens.
8. Stop normal output during recovery and queue later events under M2-E17 limits.
9. On recovery queue overflow, create a new gap identity and invalidate every old transaction token.
10. Add the suffix selection and completion transitions.
11. Remove queued events covered by the accepted completion token.
12. Cancel the transaction on detach, attachment replacement, or receiver `DOWN`.
13. Expose only the internal server operations that M2-E26 must wrap.
14. Record the application-crash limitation in the contract and proof.

### Expected file plan

- `lib/jido_console/session/recovery.ex`
- `lib/jido_console/session/reducer.ex`
- `lib/jido_console/session/state.ex`
- `lib/jido_console/session/delivery.ex`
- `lib/jido_console/session/server.ex`
- Protocol schema, generated files, and recovery examples
- `test/jido_console/session/recovery_test.exs`
- Focused reducer, state, delivery, and server recovery tests

No TUI, automation, text, or JSON adapter belongs in this pull request.

### Test and evidence matrix

| Case | Required result |
| --- | --- |
| Attach snapshot | Exact baseline at `S`; no repeated snapshot on normal output |
| Snapshot at byte limit | Valid |
| Snapshot above byte limit | Typed failure; no truncation |
| Renderer or runtime value in snapshot | Rejected |
| Events after snapshot | Contiguous suffix `S + 1` through `T` |
| Empty suffix | Valid with `T == S` |
| Missing, duplicate, reversed, stale, or future event | Typed failure and unchanged state |
| Wrong session, client, attachment, or token | Typed identity failure |
| Suffix count or byte overflow | `recovery_window_exceeded`; no truncation |
| Event during recovery | Queued, ordered, and not sent early |
| Completion through `T` | Queue through `T` removed; next output starts at `T + 1` |
| New queue overflow during recovery | New `recovery_queue_overflow` gap; old tokens invalid; new snapshot required |
| Old completion token after recovery overflow | Typed stale-token failure; new gap unchanged |
| Detach or receiver death | Transaction cancelled and state removed |
| Application restart | Transaction cannot continue |
| Live reduction versus snapshot plus suffix | Equal canonical state and derived views |

### Completion boundary and handoff

M2-E18 is complete when attach and gap recovery use bounded canonical data,
recovery cannot resume early, snapshot plus suffix equals live owner state, and
all identity, size, order, race, detach, and crash-limit tests pass.

M2-E26 wraps these typed operations in the public `Session.Client` contract.
M2-E18 does not define renderer callbacks or migrate a client.

### Risks and controls

- Long history can exceed the snapshot limit. Fail with a typed result and leave lossy compaction for Milestone 3.
- Events can arrive during snapshot application. Hold them in the bounded recovery queue and return a suffix.
- Events can arrive after suffix selection. Keep them for normal output after completion.
- An old attachment can submit a completion token. Bind all tokens to the exact attachment and recovery transaction.
- Recovery can loop during a fast stream. Return one typed window failure and require a new current snapshot.

## Acceptance Checks

- Attach and explicit recovery use one bounded canonical snapshot format.
- Full snapshots are not used for ordinary live updates.
- Snapshot and suffix restore the same semantic state as the owner.
- Recovery validates protocol version, identities, sequences, and total encoded sizes.
- Suffix events are contiguous, ordered, bounded, and never truncated silently.
- Stale, repeated, future, cross-session, malformed, and oversized recovery data is rejected.
- A failed recovery leaves client and server state unchanged.
- Normal delivery stays stopped until exact recovery completion.
- Events admitted during recovery remain ordered and bounded.
- Recovery queue overflow creates a new gap identity and invalidates all earlier recovery tokens.
- A recovered client resumes at the first sequence after the completed recovery range.
- Recovery is not described as application-restart recovery or durable resume.

## Proof Artifacts

- Gap and recovery state machine
- Snapshot schema and size result
- Event-suffix schema and order result
- Snapshot-plus-suffix equivalence result
- Stale and cross-session denial results
- Recovery race and queue-bound results
- Milestone 3 durability limitation record

## Milestone Traceability

This epic completes process-lifetime attach and gap recovery for the
Milestone 2 session plane. It does not take restart-safe work from Milestone 3.
