---
epic: M2-E32
type: epic
title: Remove the Old TUI-Owned Session Path
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e32
depends_on: [M2-E31]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E32: Remove the Old TUI-Owned Session Path

## Goal

Delete the isolated legacy TUI runtime-event path after production parity
passes, without a behavior change.

## Scope

- Start from the exact legacy inventory from M2-E27 and the passing M2-E31 proof.
- Delete the unused raw TUI event projector and raw-only state branches.
- Delete dead raw-message helpers, options, adapters, fixtures, and tests.
- Delete any raw runtime-to-client broadcast implementation left after M2-E27.
- Update only references that point to deleted implementation.
- Keep the approved Jidoka runtime ingress in the session owner.
- Add a strict source-boundary guard that prevents the client path from returning.
- Rerun the M2-E31 parity proof without a fixture or oracle change.

## Out of Scope

- New TUI behavior or a visual change
- Replacement behavior for deleted code
- Changes to canonical event mapping, delivery, recovery, or the client contract
- Changes to automation, text, or JSON behavior
- Removal of approved Jidoka ingress into `Session.Server`
- Application-restart recovery
- A release candidate or release audit

## Dependencies

This epic depends on M2-E31 because production parity must pass before the
isolated implementation is deleted.

## Pull Request Boundary

Deliver this epic in exactly one deletion-only pull request. The pull request
deletes the reviewed inventory, updates direct references, adds the no-return
guard, and reruns existing proof. It cannot add replacement product behavior.

## Detailed Delivery Plan

### Preconditions

- M2-E27 has removed every reachable raw TUI client route and server broadcast.
- M2-E27 has supplied an exact list of isolated files, branches, tests, options, and fixtures.
- M2-E31 passes through all production client entry points.
- The canonical TUI is the only selectable production terminal path.

If an inventory item is still reachable or supports required behavior, return
the defect to M2-E27 or the correct owner. Do not replace its behavior in
M2-E32.

### Decisions and invariants

The initial deletion inventory must include, when still present:

- `lib/jido_console/cli/tui/event_projection.ex`
- Raw `{:jidoka, event}` TUI transitions
- Raw Jidoka event functions in TUI turn and state modules
- Raw runtime-result and pending-review branches made unreachable by M2-E27
- Dead `session_runtime_*` and `session_control_result` helpers
- Legacy-path options, adapters, and compatibility switches
- `test/jido_console/cli/tui/event_projection_test.exs`
- Raw-only cases in TUI loop, state, turn, view, and terminal tests
- Weak string-only legacy checks
- Documentation that describes the removed client path

The pull request must not delete:

- `Session.Server` handling of inbound `{:jidoka_turn_event, event}`
- `Session.Jidoka` or `Session.Projection`
- Approved Jidoka compatibility and integration tests
- Provider-free runtimes that send Jidoka events to the session owner
- Canonical `Session.Client` projections or M2-E31 fixtures

The source-boundary guard scans syntax, not only strings. It rejects aliases,
calls, message patterns, raw broadcast helpers, options, and fallback entry
points that restore TUI ownership or direct runtime consumption. One deliberate
violation fixture must prove that the guard fails. The allowlist contains only
the exact internal Jidoka ingress into the session owner.

M2-E31 is rerun without changes. If deletion changes a semantic ledger,
production path, or side effect, restore the deletion and return the defect to
the owner. Do not correct behavior in this epic.

### Delivery steps

1. Record the exact source, test, fixture, option, and documentation inventory before deletion.
2. Verify that each item is unreachable from production entry points.
3. Delete isolated legacy modules and raw-only branches.
4. Delete raw-only helpers, options, adapters, fixtures, and tests.
5. Update direct references to the deleted implementation.
6. Add the strict source-boundary guard and exact internal-ingress allowlist.
7. Add a deliberate violation fixture and prove that the guard rejects it.
8. Run focused TUI, terminal, PTY, detach, and recovery tests.
9. Rerun the complete M2-E31 parity proof without changes.
10. Record the final zero-match report and the approved ingress list.

### Expected file plan

- `lib/jido_console/cli/tui/event_projection.ex`, deleted if present
- Raw-only branches in TUI state, turn, loop, or helper modules, deleted
- Raw-only TUI tests and fixtures, deleted or replaced only by existing canonical fixtures
- Legacy options, adapters, and documentation references, deleted
- One strict source-boundary test and deliberate violation fixture
- M2-E31 proof artifacts, rerun without an oracle change

### Test and evidence matrix

| Case | Required result |
| --- | --- |
| Before inventory | Every deletion target has a reachability result |
| Production source scan | No raw TUI client or runtime broadcast path |
| Deliberate violation fixture | Guard fails for a representative old pattern |
| Approved server ingress | Internal Jidoka-to-owner integration still passes |
| TUI unit and terminal suite | No behavior change |
| Production PTY path | Canonical TUI completes the provider-free workflow |
| Detach and reattach | Work and semantic state remain correct |
| Gap recovery | Snapshot, suffix, and resume remain correct |
| M2-E31 parity rerun | Same ledgers, entry paths, and side effects |
| Compatibility selection | No option, flag, shim, or fallback can select the old path |
| After inventory | Zero unapproved matches; exact allowlist only |

### Completion boundary and handoff

M2-E32 is complete when all reviewed legacy items are deleted, only the
approved session-owner Jidoka ingress remains, the strict guard rejects a
deliberate old pattern, and M2-E31 passes without a proof change.

M2-E36 receives this exact source for post-closeout candidate proof. M2-E32
does not add replacement behavior, rework another client, or qualify the
release artifact.

### Risks and controls

- A broad scan can reject valid Jidoka ingress. Use an exact syntax allowlist for the session owner.
- A dead-looking branch can still support behavior. Prove reachability before deletion and rerun M2-E31 unchanged.
- A compatibility option can retain duplicate ownership. Scan options and entry points, not only modules.
- Test deletion can hide lost coverage. Keep canonical behavior coverage in the existing parity and TUI suites.

## Acceptance Checks

- The deletion inventory is complete and reviewed before removal.
- No production TUI module aliases, calls, stores, or matches raw Jidoka or runtime values.
- No runtime-to-client broadcast helper remains.
- The only raw Jidoka event ingress is the approved session-owner boundary.
- No option, feature flag, fallback, alternate entry point, or shim selects the old path.
- The TUI owns only renderer-local state and renderer-local effect workers.
- M2-E31 production parity passes without changes.
- TUI terminal, PTY, detach, recovery, and cleanup tests pass.
- The source-boundary guard fails against the deliberate violation fixture.
- The pull request adds no replacement product behavior.

## Proof Artifacts

- Before-deletion inventory and reachability report
- After-deletion zero-match report
- Approved internal-ingress list
- Strict source-boundary result
- Deliberate violation result
- M2-E31 parity rerun
- TUI ownership report

## Milestone Traceability

This epic removes the isolated legacy TUI route after parity. The next epic
must qualify the new post-closeout production candidate.
