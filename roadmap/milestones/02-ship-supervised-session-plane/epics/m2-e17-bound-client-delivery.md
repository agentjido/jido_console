---
epic: M2-E17
type: epic
title: Bound Client Delivery
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e17
depends_on: [M2-E07, M2-E09, M2-E13]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E17: Bound Client Delivery

## Goal

Deliver canonical Console updates to each attachment with fixed mailbox,
queue, and copied-payload bounds.

## Scope

- Keep one bounded delivery state in the session owner for each attachment.
- Bind delivery and acknowledgement to exact session, client, and attachment identities.
- Send at most one small readiness advisory to a receiving process.
- Let the client pull one bounded canonical output batch after it reads the advisory.
- Add the v1 process-lifetime delivery family and deprecate the canonical gap event without breaking old reads.
- Define acknowledgement, timeout, duplicate, overflow, gap, detach, and client-stop behavior.
- Route every canonical `Session.Client` live update through this boundary.
- Deliver normal canonical events instead of repeated full snapshots.
- Prove receiver mailbox, queued payload, and copied response bounds from the receiving process.
- Keep all delivery state process-lifetime only.

## Out of Scope

- Snapshot and gap recovery implementation
- Production TUI migration
- Removal of the named temporary raw TUI route
- Application-restart recovery
- Durable input or delivery receipts
- Remote client transport
- Multi-user authorization

## Dependencies

This epic depends on M2-E07 for process-lifetime identities, M2-E09 for
canonical Console events, and M2-E13 for the session owner. M2-E09 is a direct
closeout dependency because the reopened delivery work cannot accept an
unfinished canonical projection.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
bounded delivery state machine, readiness advisory, output pull, exact
acknowledgement, timeout, gap transition, declared limits, and focused proof.
It must not implement recovery or migrate a production client.

## Detailed Delivery Plan

### Preconditions

- M2-E09 supplies valid canonical Console events.
- M2-E07 supplies exact attachment identity.
- M2-E13 keeps delivery state inside the session owner.
- The protocol validator can measure a complete encoded envelope.

### Decisions and invariants

Do not add one process for each client. The session owner keeps one delivery
record for each exact attachment. The record has these states:

```text
open -> ack_required -> open
open | ack_required -> gapped
gapped -> recovering
recovering -> open | gapped
open | ack_required | gapped | recovering -> detached
```

A `recovering -> gapped` transition creates a new gap identity. It invalidates
the old gap, recovery, suffix, completion, acknowledgement, and timer tokens;
clears queued recovery payload; retains the last acknowledged sequence; records
the current owner sequence and a bounded reason; and makes one readiness
advisory available. A stale token from the earlier recovery transaction cannot
change the new gap.

The receiving process gets only this small advisory:

```text
{:jido_console_session, attachment_id, :output_ready}
```

The advisory contains no semantic payload and grants no authority. Only one
unread advisory can exist for an attachment. The client pulls a bounded batch
through the E26 public facade. Before E26, E17 proves the same operation at the
session-server boundary.

An output pull returns only canonical protocol envelopes plus process-lifetime
delivery metadata. It creates one opaque acknowledgement token. A second pull
before acknowledgement returns `:ack_required` and does not copy the batch
again.

Protocol version 1 adds a `delivery` family for process-lifetime client data:

| Type | Required bounded data |
| --- | --- |
| `delivery.output_batch` | Protocol, session, client, attachment, batch, first sequence, through sequence, acknowledgement token, canonical event envelopes |
| `delivery.gap` | Protocol, session, client, attachment, gap, last acknowledged sequence, current owner sequence, bounded reason |

`delivery.output_batch` and `delivery.gap` are validated protocol values, but
they are not canonical Console events. They do not enter semantic history,
reduce shared state, replay as session events, or consume a Console sequence.
Only the canonical event envelopes inside an output batch have Console
sequences.

The current v1 schema entry `event.delivery_gap` remains as a deprecated,
input-only compatibility type so old fixtures and recorded values can still be
read. No production path can emit it or admit it to new history after M2-E17.
The generated Elixir and TypeScript types and protocol documentation must mark
it deprecated. A source-boundary test rejects new `event.delivery_gap`
construction. Removing the old type requires a later breaking protocol version;
adding the `delivery` family is additive in v1. M2-E18 extends this family with
recovery data, and M2-E26 exposes it as typed public results.

Use these maximum limits:

| Limit | Maximum value |
| --- | ---: |
| Unread readiness advisories per attachment | 1 |
| Queued canonical updates per attachment | 32 |
| Encoded queued payload per attachment | 1,048,576 bytes |
| Updates in one pulled batch | 16 |
| Encoded pulled batch | 262,144 bytes |
| Encoded readiness advisory | 4,096 bytes |
| Acknowledgement timeout after a pull | 5,000 ms |
| Copied semantic payload for one unacknowledged pull | 262,144 bytes |

Configuration can lower a limit. It cannot increase a limit above this table.

An acknowledgement means that the exact attachment validated and applied the
batch through the token sequence. It does not mean mailbox receipt, durable
storage, or restart-safe acceptance. The token binds session, client,
attachment, batch, and through-sequence identities.

- The exact repeated acknowledgement is an idempotent no-op.
- A lower acknowledgement is stale.
- A higher or fabricated acknowledgement is future or invalid.
- An old attachment acknowledgement is an identity mismatch.
- An acknowledgement cannot clear a gap.

Do not trust a caller-provided `coalesce` flag. For protocol version 1, no
distinct semantic event is replaceable. Suppress only the exact repeated event
ID and sequence. A later protocol version can add a closed generated
coalescing policy.

When count, bytes, event size, or acknowledgement time exceeds a limit, change
the attachment to `gapped`. Clear queued semantic payload, retain only bounded
gap data, and make sure that one readiness advisory exists. Later offers do not
send or queue semantic payload until M2-E18 completes recovery. A gap is
client-specific delivery data. It does not enter canonical session history or
consume a Console sequence.

The named legacy TUI runtime route is not part of the new `Session.Client`
channel. M2-E27 removes its active use and server broadcasts. M2-E32 deletes
isolated legacy code. No new client can use that route.

### Delivery steps

1. Add exact attachment identity and delivery bounds to the protocol data.
2. Add `delivery.output_batch` and `delivery.gap` to the v1 schema and regenerate protocol artifacts.
3. Deprecate `event.delivery_gap` for input compatibility and prohibit new production emission.
4. Add the readiness advisory and bounded output-batch result.
5. Replace sender-only pending tracking with the explicit state machine.
6. Offer the admitted canonical event, not `Reducer.snapshot/1`, for a normal update.
7. Keep at most one unread readiness advisory for each attachment.
8. Add one owned batch and acknowledgement token for each output pull.
9. Add exact acknowledgement and idempotent retry rules.
10. Add timer tokens and reject stale timeout messages.
11. Add count, byte, event-size, timeout, and recovery-overflow gap transitions.
12. Invalidate all old tokens when recovery creates a new gap.
13. Cancel timers and clear delivery state on detach, replacement attach, and receiver `DOWN`.
14. Add source checks that forbid direct semantic payload sends on the new client channel.
15. Record the temporary raw TUI route in the M2-E27 removal inventory.

### Expected file plan

- `lib/jido_console/session/delivery.ex`
- `lib/jido_console/session/server.ex`
- `priv/session/protocol/jido.session.v1.json`
- Generated Elixir and TypeScript protocol files
- Delivery protocol examples
- `test/jido_console/session/delivery_test.exs`
- Focused session-server delivery tests
- One stopped-receiver mailbox and payload proof test

No renderer or production client adapter belongs in this pull request.

### Test and evidence matrix

| Case | Required result |
| --- | --- |
| First update | One readiness advisory and one queued update |
| More updates before pull | No second advisory; bounded FIFO queue |
| Pull within limits | One ordered batch and one exact token |
| Second pull before ack | `:ack_required` and no second payload copy |
| Exact or repeated exact ack | Advance once; repeated ack is unchanged |
| Stale, future, fabricated, or old-attachment ack | Typed error and unchanged state |
| Queue count or byte overflow | One gap, cleared payload queue, no later growth |
| Oversized event | `update_too_large` gap before client copy |
| Acknowledgement timeout | One gap matched by attachment and timer token |
| Queue overflow during recovery | New gap identity; all old transaction tokens invalid |
| Stale timer | No effect on a newer batch |
| Two clients | Independent queues, tokens, timers, gaps, and progress |
| Client death or detach | Exact delivery state and timer removed |
| 10,000 events to a stopped receiver | Mailbox at most one advisory; queue and bytes stay bounded |
| Normal model and tool updates | Canonical event batches, never repeated snapshots |
| Protocol compatibility | New delivery family accepted; old event gap readable but never emitted |
| Delivery gap sequence | No Console sequence and no canonical history entry |

The receiver proof measures `message_queue_len` and
`:erlang.external_size/1`. It uses an isolated receiver that does not read, a
slow receiver, and a receiver that stops after its first output pull.

### Completion boundary and handoff

M2-E17 is complete when the declared limits, stopped-receiver proof, exact
acknowledgement proof, timeout proof, independent-client proof, and
incremental-update proof pass.

M2-E18 receives a typed `delivery.gap` state with exact identities, last
acknowledged sequence, owner sequence, reason, and the transition that replaces
an overflowing recovery with a new gap. M2-E17 does not build a snapshot,
select a replay suffix, or reopen the attachment.

### Risks and controls

- A repeated advisory can grow the receiver mailbox. Track one outstanding advisory in owner state.
- A large valid map can exceed the batch limit. Measure the complete encoded envelope.
- A stale timer can gap a new batch. Match the attachment and a unique timer token.
- Caller-controlled coalescing can lose semantic data. Permit exact duplicate suppression only.
- An old recovery token can reopen a new gap. Replace the gap identity and invalidate every old transaction token.
- The old canonical gap event can enter new history. Keep it input-only and reject every production constructor.

## Acceptance Checks

- Each attachment has fixed count, byte, batch, advisory, and timeout bounds.
- Every new `Session.Client` live update uses this delivery boundary.
- The receiver mailbox contains at most one unread readiness advisory for an attachment.
- A stopped receiver cannot cause unbounded server queue or copied payload growth.
- Normal output contains ordered canonical events, not repeated full snapshots.
- Acknowledgements bind exact session, client, attachment, batch, and sequence identities.
- Unsafe updates are never coalesced or dropped silently.
- Exact duplicate suppression does not change semantic state.
- A gap is explicit, bounded, client-specific, and not part of canonical history.
- A gap uses `delivery.gap`; it does not consume a Console sequence.
- The deprecated `event.delivery_gap` type remains readable but cannot be emitted or admitted to new history.
- No payload is queued or sent after a gap until recovery succeeds.
- Delivery state is not described as durable input or restart-safe receipt state.
- The temporary raw TUI route remains explicitly assigned to M2-E27 and M2-E32.

## Proof Artifacts

- Client delivery state machine
- Declared delivery-limit table
- Readiness, output, and acknowledgement contract
- Slow-client and stopped-client receiver results
- Queue and copied-payload memory results
- Gap and timeout results
- Delivery-family schema, generated artifacts, and compatibility result
- Recovery-overflow token-invalidation result
- Incremental semantic-update result

## Milestone Traceability

This epic provides the bounded process-lifetime delivery mechanism used by
the Milestone 2 client contract. M2-E27 and M2-E32 still own the temporary raw
TUI route removal.
