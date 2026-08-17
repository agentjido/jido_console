---
epic: M2-E27
type: epic
title: Migrate the TUI to Session.Client
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e27
depends_on: [M2-E26]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E27: Migrate the TUI to Session.Client

## Goal

Make the production terminal UI a semantic `Session.Client` projection with no
reachable raw runtime-event route.

## Scope

- Use `Session.Client` for attach, status, input, commands, output, acknowledgement, recovery, cancel, and permission response.
- Apply normal canonical event batches to the TUI reducer.
- Apply a full snapshot only during attach or explicit recovery.
- Render model, tool, permission, control, failure, cancellation, and terminal data from canonical Console values.
- Use the typed `start_turn` result to install the active Console request.
- Keep draft, terminal size, cursor, scroll, history navigation, and render scheduling in the TUI process.
- Remove all reachable raw `session_runtime_*`, `session_control_result`, and `{:jidoka, event}` paths.
- Stop the session server from broadcasting raw runtime messages to attached clients.
- Keep Jidoka runtime ingress inside the session owner.
- Leave isolated and unreachable raw-only files for M2-E32 deletion when this keeps the migration reviewable.
- Add no feature flag, fallback, or compatibility shim.

## Out of Scope

- Deletion of isolated unreachable legacy files and legacy-only tests
- Changes to canonical Jidoka projection
- Changes to automation, text, or JSON adapters
- New TUI features or visual redesign
- Application-restart recovery or durable input receipt
- LiveView, SSH, or remote clients

## Dependencies

This epic depends on M2-E26 for the final `Session.Client` API, bounded output,
recovery operations, typed control and permission results, and reusable suite.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request cuts the
production TUI over to the canonical client contract and removes the active
raw client route. It must not delete isolated legacy implementation that is
better reviewed in M2-E32, and it must not migrate another client.

## Detailed Delivery Plan

### Preconditions

- The M2-E26 default driver passes its reusable contract suite.
- Canonical output covers start, model, tool, permission, control, failure, cancellation, and completion data.
- Attach and recovery snapshots use the M2-E18 format.
- The current raw receive clauses, broadcasts, projection helpers, and state branches are inventoried.

### Decisions and invariants

The production TUI owns rendering only. It does not own a Jidoka session,
runtime request, worker result order, canonical event order, delivery queue,
or permission authority.

Use this input map:

| TUI need | Canonical source |
| --- | --- |
| Initial transcript and active run | Attach snapshot |
| Turn request identity | Typed `start_turn` result |
| Model stream | Ordered `model_delta` output |
| Tool activity | `tool_started`, `tool_completed`, and `tool_failed` output |
| Permission prompt and result | `permission_requested` and `permission_decided` output |
| Control result | Canonical control output |
| Completion, failure, cancellation, or hibernation | Canonical terminal output |
| Lost delivery | Explicit gap and recovery operations |

The TUI loop handles the one readiness advisory. It pulls one bounded output
batch, validates each envelope, reduces the batch in sequence, and
acknowledges only after the full batch is applied. A failed envelope does not
advance the local sequence or acknowledgement.

On a gap, the TUI stops normal reduction. It performs M2-E26 recover, replay,
and resume once, applies the snapshot and suffix through the same semantic
restore boundary, and then returns to normal output. It does not request a
snapshot for each normal update.

The TUI state can keep only renderer-local values such as draft, cursor,
scroll, terminal dimensions, selected view, and render timing. It cannot keep
a `Jidoka.Event`, `Jidoka.Stream`, raw runtime result, runtime pending-review
value, PID-owned request, or raw event sequence.

The production TUI no longer receives raw server broadcasts after cutover.
The server continues to accept internal Jidoka runtime ingress and project it
through M2-E09. Isolated dead projector modules can remain until M2-E32, but no
production call or option can reach them.

### Delivery steps

1. Add one TUI semantic projection over canonical Console envelopes.
2. Change TUI state and turn records to reduce semantic event types.
3. Use the typed turn-start result for current request and run identity.
4. Replace raw completion, review, tool, and control data with canonical values.
5. Handle the readiness advisory and pull bounded output through `Session.Client`.
6. Apply a batch in order and acknowledge only after successful reduction.
7. Use one state-restore function for attach and recovery snapshots.
8. Add explicit gap, replay, and resume behavior.
9. Remove reachable raw runtime receive clauses and state transitions.
10. Remove raw runtime broadcasts from the session server client path.
11. Keep runtime setup and model reconfiguration behind typed client operations.
12. Run the real TUI entry point through deterministic terminal and PTY tests.
13. Record the remaining isolated deletion inventory for M2-E32.

### Expected file plan

- `lib/jido_console/cli/tui.ex`
- `lib/jido_console/cli/tui/state.ex`
- `lib/jido_console/cli/tui/turn.ex`
- `lib/jido_console/cli/tui/effects.ex`
- `lib/jido_console/cli/tui/shutdown.ex`
- `lib/jido_console/session/client/tui.ex`
- `lib/jido_console/session/server.ex`
- One semantic TUI projection module, if needed
- TUI reducer, terminal, PTY, detach, recovery, and cleanup tests

M2-E27 can make raw-only files unreachable. M2-E32 owns their deletion.

### Test and evidence matrix

| Case | Required result |
| --- | --- |
| Attach | Snapshot restores transcript and active run once |
| `run_started` and `model_delta` | Ordered live rendering without a full snapshot |
| Tool start, completion, and failure | Correct canonical tool state |
| Permission request and decision | Exact prompt and result with no raw review value |
| Control request and result | Canonical state and visible result |
| Completion, failure, cancellation, hibernation | One terminal TUI state |
| Invalid, duplicate, stale, or cross-session output | Typed failure or no-op; no state corruption |
| Successful batch | Acknowledgement only after full apply |
| Gap and recovery | Snapshot plus suffix, then correct resume sequence |
| Failed recovery | No early resume and no local state corruption |
| Detach during model, tool, or permission work | Session and worker continue |
| Reattach | Same ordered semantic state at the current sequence |
| Raw tuple injection | No TUI state change |
| Stopped renderer | M2-E17 mailbox and payload limits remain valid |
| Terminal cleanup | Terminal, workers, monitor, and attachment close exactly once |
| Production PTY | Complete provider-free smoke workflow |

### Completion boundary and handoff

M2-E27 is complete when the production TUI uses only `Session.Client`, the
server sends no raw runtime message to an attached client, detach and reattach
work during active execution, and all TUI, terminal, PTY, gap, recovery,
boundedness, and cleanup tests pass.

M2-E31 proves this path with the other production clients. M2-E32 receives the
exact inventory of isolated raw-only modules, branches, tests, options, and
fixtures that remain. M2-E27 must not delete unrelated legacy code or add new
behavior.

### Risks and controls

- Canonical output can omit a TUI-only runtime detail. Return the gap to M2-E09, M2-E23, M2-E24, or M2-E26 instead of adding a private TUI route.
- A batch can be acknowledged before it is applied. Reduce the full batch first and acknowledge last.
- Renderer-local state can leak into snapshots. Test the shared state before and after every renderer action.
- Cutover can stop active work on detach. Keep session ownership in the server and test three active-work states.

## Acceptance Checks

- The production TUI starts, controls, and observes work only through `Session.Client`.
- The TUI handles canonical output, attach snapshots, gaps, recovery, and typed command results.
- Ordinary output updates the renderer without a full snapshot.
- The TUI acknowledges only canonical data that it applied successfully.
- Gap recovery stops normal reduction and resumes at the exact recovery sequence.
- Model, tool, permission, control, failure, cancellation, and terminal views use canonical Console data.
- No reachable TUI code consumes a raw Jidoka event, stream, runtime result, or raw session message.
- No attached client receives a raw runtime broadcast from `Session.Server`.
- A raw tuple injected into the TUI mailbox does not change state.
- The TUI can detach during active work without stopping the session or worker.
- A new attachment restores the same ordered semantic state.
- Draft, terminal dimensions, cursor, scroll, and render timing remain client-local.
- TUI reducer, terminal, PTY, detach, recovery, boundedness, and cleanup tests pass.

## Proof Artifacts

- Production TUI-to-`Session.Client` operation map
- Canonical receive-loop inventory
- Detach and reattach transcript
- Gap and recovery transcript
- Local-state isolation result
- Raw-message absence scan
- Stopped-renderer bound result
- Production PTY transcript
- M2-E32 deletion inventory

## Milestone Traceability

This epic completes the production TUI cutover and removes the active raw
client route. M2-E32 still owns deletion of isolated legacy implementation.
