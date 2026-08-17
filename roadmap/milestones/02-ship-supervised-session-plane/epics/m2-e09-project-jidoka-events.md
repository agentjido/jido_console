---
epic: M2-E09
type: epic
title: Project Jidoka Events at One Boundary
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e09
depends_on: [M2-E06, M2-E08]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E09: Project Jidoka Events at One Boundary

## Goal

Convert each approved portable Jidoka event into one deterministic, bounded,
and classified Console event candidate at one controlled boundary.

## Scope

- Consume Jidoka event data only through the approved public integration facade.
- Define one complete Jidoka-to-Console event mapping table.
- Preserve the Console session, request, and run identities.
- Preserve each available Jidoka request, turn, effect, and source-event identity.
- Dedupe events with a bounded caller-owned admission cursor.
- Validate order separately for each Jidoka request stream.
- Accept the next Console sequence from the session owner without storing sequence state.
- Convert a projection rejection into a bounded typed failure. Do not require a raw client error tuple.
- Keep raw runtime values, private structs, authority data, and unbounded unknown data out of Console events.
- Make this boundary the only producer of canonical Console events from Jidoka runtime data.
- Record the temporary raw TUI route as migration debt owned by M2-E27 and M2-E32.

## Out of Scope

- Session-server ownership
- TUI reducer or renderer changes
- TUI route cutover
- Deletion of raw TUI broadcast or projection code
- Client delivery, acknowledgement, or recovery
- Durable event storage
- Direct access to private Jidoka runtime modules

## Dependencies

This epic depends on M2-E06 for the pinned Jidoka integration and M2-E08 for
Console event classification.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request completes the
canonical projection, identity preservation, terminal arbitration,
deduplication, order checks, and deterministic fixtures. It must not change a
TUI module or migrate a client.

## Detailed Delivery Plan

### Preconditions

- The Jidoka version and approved facade from M2-E06 are fixed.
- The event classification and protocol bounds from M2-E08 are available.
- The implementation has an inventory of every supported portable Jidoka event name.
- The session owner supplies the active Console session, request, and run context.
- The session owner supplies and stores the bounded projection admission cursor.

### Decisions and invariants

The projection is a pure function. It receives the portable event, owner
context, caller-owned admission cursor, and next Console sequence. It does not
own a process, subscription, sequence, timer, cursor, or event store. Its
result is one of these values:

```text
{:ok, canonical_console_event, next_admission_cursor}
{:hold_terminal, terminal_candidate, next_admission_cursor}
{:ignore, :duplicate, unchanged_admission_cursor}
{:error, typed_reason, unchanged_admission_cursor}
```

The session owner keeps one cursor for each owner-approved active Jidoka
request. A cursor contains the request identity, last accepted source sequence,
terminal-candidate state, and a ring of recent source sequence, event identity,
and SHA-256 digest values for the normalized portable event. Use these maximum
limits:

| Admission cursor limit | Maximum value |
| --- | ---: |
| Active Jidoka request cursors per session | 64 |
| Recent source-event digests per cursor | 64 |
| Digest size | 32 bytes |

Configuration can lower these limits. It cannot increase them. An active
cursor is never evicted. A sixty-fifth active request fails with
`projection_cursor_limit` before projection. When the ring is full, discard
the oldest digest but retain the last accepted source sequence. An older event
outside the ring fails as `stale_source_event`; it is never admitted as new.

An exact identity and digest match inside the ring is a duplicate. The same
source sequence with a different identity or digest is
`source_event_conflict`. Only the next contiguous source sequence can advance
the cursor. Jidoka request streams start at source sequence `0`. A new cursor
expects `0`. A negative value is `invalid_source_sequence`; a first sequence
above `0` is `source_sequence_gap`; and an event for a request that the owner
already marked closed is `stale_source_event`.

For a non-terminal event, the caller atomically commits the canonical event and
returned cursor. For a terminal source event, the caller atomically commits the
returned cursor and a bounded terminal candidate without admitting a final
Console event. A duplicate or error never changes the cursor.

After terminal arbitration and exact request cleanup, the owner removes the
cursor and marks the request closed in semantic state. A late event for a
closed or unknown request fails before projection. Thus, cursor cleanup cannot
make an old event valid again.

Use this minimum event mapping:

| Jidoka source | Console type |
| --- | --- |
| `llm_delta` | `model_delta` |
| `effect_planned`, `effect_started`, `capability_call_started` | `tool_started` |
| `effect_replayed`, `effect_completed`, `capability_call_completed`, `operation_observed` | `tool_completed` |
| `effect_failed`, `capability_call_failed` | `tool_failed` |
| `approval_requested` | `permission_requested` |
| `approval_responded`, `approval_applied` | `permission_decided` |
| `turn_finished` | terminal completion candidate |
| `turn_failed` | terminal failure candidate |
| `turn_hibernated` | the protocol-defined paused or terminal state |
| Other known bounded events | `run_progress` |

Descriptive policy or control data cannot create approval authority. It becomes
`run_progress` unless M2-E24 supplies an exact permission identity and response
operation.

The identity map contains:

- Console session identity
- Console request identity
- Console run identity
- Jidoka request identity
- Jidoka turn identity, when present
- Jidoka effect identity as the Console step identity, when present
- Jidoka source-event identity, derived from the request identity and event sequence

The session result is authoritative for final content and status. The cursor
terminal state is `none`, `event_pending`, `result_pending`, or `finalized`.
A terminal Jidoka event still passes order, identity, and duplicate checks.
If the event arrives first, `{:hold_terminal, ...}` advances the cursor and
stores `event_pending`; a repeated terminal event is then a duplicate while the
runtime result is pending. If the result arrives first, the owner stores one
bounded identity-bound `result_pending` value with a normalized SHA-256 digest.
An exact repeated result identity and digest is an idempotent no-op. The same
result identity with a different digest is `terminal_result_conflict`; a stale
or cross-request identity is an identity failure. None of these results replaces
the pending value. When both event and result values exist, the owner atomically
admits exactly one final Console event and marks the cursor `finalized`.
Conflicting terminal event data also fails without replacing the pending value.
Tests cover both arrival orders and duplicate or conflicting terminal inputs
during the pending interval.

The canonical protocol does not define a raw Jidoka or runtime-event message
type. The temporary raw TUI route is outside this canonical protocol and stays
on the M2-E27 and M2-E32 removal list.

### Delivery steps

1. Inventory each supported portable Jidoka event name and its bounded fields.
2. Add the explicit mapping table to the projection boundary.
3. Pass the active Console request and run context from the session owner.
4. Add the complete identity map and deterministic source-event identity.
5. Add structured tool, permission, control, progress, and terminal candidates.
6. Add the bounded owner-owned admission cursor and atomic event-plus-cursor admission.
7. Validate per-request order, duplicate identity, payload digest, and cursor limits before semantic admission.
8. Add the atomic held-terminal cursor transition and arbitration for both arrival orders.
9. Convert projection rejection into a bounded typed or canonical failure.
10. Add a source-boundary test that rejects a second canonical Jidoka projector.
11. Add deterministic fixtures for all supported event names.

### Expected file plan

- `lib/jido_console/session/projection.ex`
- `lib/jido_console/session/jidoka.ex`
- `lib/jido_console/session/server.ex`
- `test/jido_console/session/projection_test.exs`
- `test/jido_console/session/server_test.exs`
- The Jidoka public-API boundary test
- One bounded projection fixture, if a data fixture is needed

No production TUI file belongs in this pull request.

### Test and evidence matrix

| Case | Required result |
| --- | --- |
| Every supported event name | One documented Console mapping |
| Duplicate at first, middle, or terminal position | No duplicate Console event |
| Same sequence with different identity or payload | `source_event_conflict`; cursor and semantic state unchanged |
| Missing or non-contiguous source sequence | Typed error and unchanged semantic state |
| First source sequence `0` | Accepted for a new request cursor |
| First source sequence below `0` | `invalid_source_sequence`; cursor unchanged |
| First source sequence above `0` | `source_sequence_gap`; cursor unchanged |
| First late event for a closed request | `stale_source_event` before projection |
| Two Jidoka request streams | Independent order validation |
| Sixty-four active cursors | Valid and bounded |
| Sixty-fifth active cursor | `projection_cursor_limit`; no eviction |
| Event older than the retained digest ring | `stale_source_event`; never admitted |
| Late event after request cleanup | Closed-request failure before projection |
| Terminal event before result | One final Console event |
| Result before terminal event | One final Console event |
| Duplicate terminal event while result is pending | Duplicate no-op; pending cursor unchanged |
| Conflicting terminal event while result is pending | Typed conflict; pending value unchanged |
| Duplicate result while waiting for terminal event | Idempotent no-op; pending result unchanged |
| Conflicting result while waiting for terminal event | `terminal_result_conflict`; pending result unchanged |
| Stale or cross-request pending result | Typed identity failure; pending state unchanged |
| Oversized known or unknown data | Typed bounded rejection |
| PID, reference, function, port, or private struct | Rejected before admission |
| Unknown authority field | Rejected without authority change |
| Same input, owner context, and sequence | Byte-equivalent portable result |
| Source scan | One canonical projector only |

### Completion boundary and handoff

M2-E09 is complete when the mapping corpus, identity map, terminal arbitration,
duplicate proof, invalid-order proof, raw-runtime exclusion proof, and source
scan pass.

M2-E17 consumes only the resulting canonical Console events. M2-E27 later
cuts the production TUI over to those events. M2-E32 deletes isolated legacy
projection code. M2-E09 must not take either client task.

### Risks and controls

- A wrong request-to-run correlation can corrupt event identity. Use the active owner context and test concurrent request streams.
- Runtime event and result tasks can finish in either order. Use one terminal arbitration rule and test both orders.
- A broad fallback mapping can hide unsupported authority data. Keep a closed mapping for authority-bearing events and bound all other data.
- Cursor eviction can admit an old event again. Never evict an active cursor, retain the last sequence after digest eviction, and reject closed requests.

## Acceptance Checks

- One documented mapping covers every supported portable Jidoka event name.
- Every canonical Console event derived from Jidoka data is produced by `Session.Projection`.
- The mapping preserves Console session, request, and run identities and all available Jidoka identities.
- One run admits no more than one terminal Console event.
- Duplicate source events do not create duplicate Console events.
- The session owner stores at most 64 active cursors with 64 fixed-size recent digests in each cursor.
- Cursor overflow, stale events outside the digest ring, conflicting source data, and late closed-request events fail without admission.
- The event and returned cursor are committed together or not at all.
- A held terminal candidate and its returned cursor are committed together, and duplicate terminal events cannot advance pending state.
- An exact repeated pending runtime result is idempotent; a conflicting or wrongly identified result cannot replace it.
- A new Jidoka request cursor accepts source sequence `0` only as its first event.
- Invalid source order does not advance Console sequence or change semantic state.
- Projection rejection produces a bounded typed or canonical failure.
- Unknown data stays within protocol bounds and cannot grant authority.
- Projected data contains no live process value, private runtime struct, or raw Jidoka event struct.
- The same input event, owner context, and Console sequence produce the same result.
- The projector does not allocate or own live Console sequence state.
- The canonical protocol defines no raw Jidoka or runtime-event type.
- Temporary raw TUI route removal remains assigned to M2-E27 and M2-E32.

## Proof Artifacts

- Jidoka-to-Console mapping table
- Console and Jidoka identity map
- Complete fixture result
- Duplicate and invalid-order results
- Terminal arbitration result
- Raw-runtime exclusion result
- Projection source-boundary scan

## Milestone Traceability

This epic covers the Milestone 2 canonical Jidoka projection boundary. It
does not claim that the production TUI migration or legacy route deletion is
complete.
