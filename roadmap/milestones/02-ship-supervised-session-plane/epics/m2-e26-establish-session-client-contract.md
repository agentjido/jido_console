---
epic: M2-E26
type: epic
title: Establish the Session.Client Contract
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e26
depends_on: [M2-E16, M2-E18, M2-E20, M2-E21, M2-E22, M2-E23, M2-E24, M2-E25]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.2.0
---

# M2-E26: Establish the Session.Client Contract

## Goal

Define one renderer-neutral client boundary for all process-lifetime session
access and live semantic output.

## Scope

- Define exact session, logical-client, and attachment identities.
- Return an opaque client handle that exposes no server or runtime value.
- Define attach, detach, input, command, output, state, control, permission, delivery, recovery, and capability operations.
- Expose M2-E17 bounded output and acknowledgement without exposing internal delivery state.
- Expose M2-E18 bounded snapshot and suffix recovery without reopening delivery early.
- Keep send, steer, queue, and remove as separate operations.
- Route command effects, model content, view details, permission results, and hook results through one canonical output path.
- Resolve versioned renderer-neutral capabilities from the M2-E21 registry.
- Add a driver behavior and one reusable black-box contract suite.
- Prevent a new client adapter from using a raw Jidoka or runtime-event stream.
- Keep one named legacy TUI route on a fixed removal allowlist for M2-E27 and M2-E32 only.

## Out of Scope

- Migration of the TUI, automation, text, or JSON adapter
- Deletion of the old TUI-owned session or turn path
- Application-restart recovery or durable receipts
- Renderer callbacks or renderer state
- LiveView, SSH, external deployment, or extension loading

## Dependencies

This epic depends on M2-E16 for distinct input operations, M2-E18 for recovery,
M2-E20 for cancellation, M2-E21 for client descriptors, M2-E22 for command
effects, M2-E23 for model and view results, M2-E24 for permission results, and
M2-E25 for hook results. M2-E18 is transitively after the M2-E09 and M2-E17
closeout work.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
public contract, opaque values, registry integration, driver behavior,
reusable contract suite, and bypass guards. It must not migrate or delete an
existing production adapter.

## Detailed Delivery Plan

### Preconditions

- M2-E17 has a frozen readiness, output, token, receipt, and limit contract.
- M2-E18 has a frozen snapshot, suffix, recovery, and completion contract.
- M2-E20 through M2-E25 supply typed control, registry, effect, result, permission, and hook values.
- The named legacy TUI raw route is fully inventoried and cannot grow.

### Decisions and invariants

Use three identities:

| Identity | Meaning |
| --- | --- |
| Session | One supervised semantic session |
| Client | One logical process-lifetime client |
| Attachment | One exact connection of that client to the session |

Each attach creates a new attachment. Every operation validates all three
identities. An old handle cannot detach, acknowledge, recover, control, or
otherwise affect a replacement attachment.

The public handle is opaque. It contains stable public identity, protocol, and
capability data plus private implementation data. It does not expose a server
PID, monitor reference, delivery state, runtime handle, Jidoka request, task,
port, or raw snapshot cache.

Attach performs these operations in order:

1. Resolve and validate a versioned client descriptor.
2. Check protocol compatibility and required capabilities.
3. Negotiate optional capabilities and delivery limits.
4. Create an exact attachment identity and monitor the receiver.
5. Capture one bounded canonical attach snapshot.
6. Set the M2-E17 delivery baseline to the snapshot sequence.
7. Return the opaque handle, negotiated capabilities, and snapshot.

The receiver gets at most one M2-E17 readiness advisory. It calls the output
operation to pull a bounded batch. Each returned item contains process-lifetime
delivery metadata and one canonical protocol envelope. A second pull before
acknowledgement returns `ack_required` and cannot copy the same batch again.
The facade validates M2-E17 `delivery.output_batch` and `delivery.gap` values.
A gap is a typed delivery result, not a canonical Console event or history
entry. The facade never exposes the deprecated `event.delivery_gap` type to a
new client.

Acknowledgement uses an opaque token from the batch. It returns a public
process-lifetime receipt, not `Session.Delivery` state. The exact repeated token
is idempotent. Stale, future, fabricated, cross-session, and old-attachment
tokens fail without state change. An acknowledgement cannot clear a gap.

Recovery has three public phases:

1. `recover` returns the bounded snapshot and a recovery token.
2. `replay` returns the bounded suffix and a completion token.
3. `resume` accepts the completion token and returns a receipt or a new gap.

The attachment stays gapped or recovering until `resume` succeeds.

Use these operation groups:

| Group | Operations | Required result |
| --- | --- | --- |
| Lifecycle | attach, detach | Exact handle, snapshot, and typed lifecycle result |
| Input | send, steer, queue, remove | Separate identity-bound admission results |
| Command | invoke | Typed M2-E22 effect result |
| Output | output | Bounded canonical batch, typed delivery gap, empty, or typed error |
| State | status, snapshot | Bounded renderer-neutral values |
| Control | cancel | Exact M2-E20 result |
| Permission | approve, reject | Exact M2-E24 result |
| Delivery | ack | Public process-lifetime receipt |
| Recovery | recover, replay, resume | M2-E18 values and completion result |
| Capability | capabilities, supports? | Versioned descriptive data |

Capabilities describe supported operations. They do not grant principal,
permission, approval, scope, or authority. Unknown optional capability data
stays bounded data.

The driver behavior covers only semantic lifecycle, input, output, state,
control, delivery, recovery, and capability operations. It does not contain
TUI drawing, text formatting, JSON encoding, DOM, or transport callbacks.

The structural bypass guard permits client adapters to call `Session.Client`
and renderer-neutral value modules only. It rejects direct adapter calls to
`Session.Server`, `Session.Delivery`, `Session.Recovery`, and raw Jidoka client
APIs. Until M2-E27 lands, one exact legacy TUI route is allow-listed. The
allowlist cannot grow, and no new adapter can use it. M2-E27 removes the active
route. M2-E32 removes the allowlist and dead implementation.

### Delivery steps

1. Add opaque handle, attachment, output, acknowledgement token, receipt, recovery, capability, and error values.
2. Change attachment records to use exact attachment identity.
3. Validate the exact attachment on every public operation.
4. Add attach negotiation and the bounded attach snapshot result.
5. Add the readiness advisory and bounded output-pull facade.
6. Wrap M2-E17 acknowledgement without returning internal delivery state.
7. Wrap M2-E18 recover, replay, and resume operations.
8. Add separate send, steer, queue, remove, invoke, cancel, approve, reject, status, and snapshot operations.
9. Resolve descriptors and capabilities through the M2-E21 registry.
10. Route effects, results, permissions, and hooks through the canonical output type.
11. Add the renderer-neutral driver behavior.
12. Add the reusable ExUnit contract case.
13. Add structural and runtime bypass tests with the fixed legacy allowlist.
14. Record the process-lifetime acknowledgement and recovery limit.
15. Confirm that no production adapter file changed in this epic.

### Expected file plan

New value and behavior modules can live below:

- `lib/jido_console/session/client/`

Expected integration and test files include:

- `lib/jido_console/session/client.ex`
- `lib/jido_console/session/server.ex`
- `lib/jido_console/session/catalog.ex`
- `test/jido_console/session/client_test.exs`
- One reusable client contract case under `test/support/`
- Client identity, output, acknowledgement, recovery, capability, and boundary tests
- Focused server, delivery, and recovery integration tests

No production TUI, automation, text, or JSON adapter file belongs in this pull request.

### Test and evidence matrix

The default local driver must pass these cases:

| Case | Required result |
| --- | --- |
| Attach and reattach | New exact attachment; old handle cannot affect it |
| Detach or receiver `DOWN` | Only the exact attachment is removed; session work continues |
| Output | Canonical envelopes in monotonic order and within negotiated limits |
| Stopped reader | One readiness advisory and M2-E17 memory bounds |
| Acknowledgement | Exact token, idempotent exact retry, typed invalid-token failures |
| Gap | Normal output blocked until recovery completion |
| Delivery-family compatibility | New clients receive no deprecated canonical gap event |
| Recovery | Snapshot then suffix reaches owner-equivalent state |
| Invalid recovery | Identity, order, version, size, and token failures are typed |
| Input operations | Send, steer, queue, and remove keep distinct semantics |
| Cancel | Exact work identity and one typed terminal result |
| Permission | Exact request identity for approve and reject |
| Effect, content, view, permission, and hook data | One canonical output path |
| Status and capabilities | Bounded, renderer-neutral, and non-authoritative |
| Public values | No server, delivery, runtime, or Jidoka internals |
| Legacy route guard | One fixed TUI exception only; no new client bypass |

### Completion boundary and handoff

M2-E26 is complete when the default local driver passes the full reusable
suite, every operation validates attachment identity, all live output uses the
bounded facade, public values expose no internals, and the bypass allowlist is
fixed to the named TUI migration debt.

M2-E27 through M2-E30 use or wrap this behavior. They cannot add private
server calls or adapter-specific output channels. M2-E31 runs the suite through
the production paths. M2-E32 deletes temporary facade methods and the legacy
allowlist after parity passes.

### Risks and controls

- An old handle can affect a new attachment. Validate attachment identity on every operation.
- A capability can be mistaken for authority. Keep capabilities descriptive and require permission checks.
- A pull can copy one batch more than once. Permit one owned batch and require acknowledgement before another pull.
- Existing adapters can force migration into this PR. Keep temporary facade methods and migrate only in their owning epics.
- A source scan can give false confidence. Combine structural checks with an instrumented runtime receiver.

## Acceptance Checks

- A client attaches with exact session, client, and attachment identities.
- Reattach creates a new attachment, and an old handle cannot affect it.
- The opaque handle exposes no server PID, runtime handle, or internal delivery state.
- Every public operation validates the exact attachment.
- Live semantic payloads are pulled only through the bounded output API.
- The receiver mailbox gets at most one readiness advisory per attachment.
- All output envelopes pass the canonical protocol validator.
- Normal live output does not contain repeated full snapshots.
- Acknowledgement uses an exact opaque token and returns a public process-lifetime receipt.
- Recovery stays gapped until an exact completion token is accepted.
- Snapshot and suffix recovery reaches the same semantic state as the owner.
- Input, command, control, permission, status, and capability operations have separate typed results.
- Effects, content, view details, permissions, and hooks use the same output path.
- Capabilities come from the registry and cannot grant authority.
- The reusable behavior suite passes for the default local driver.
- No new client can use a raw Jidoka or runtime-event subscription.
- The only temporary bypass is the fixed M2-E27 TUI migration route.
- No existing production client adapter is migrated in this epic.
- The contract states that acknowledgement and recovery are not durable across application restart.

## Proof Artifacts

- Public `Session.Client` API and identity schema
- Opaque handle and public result inventory
- Renderer-neutral driver behavior
- Reusable client contract suite result
- Output, acknowledgement, and recovery results
- Cross-session and old-attachment denial results
- Capability non-authority result
- Structural and runtime bypass results

## Milestone Traceability

This epic establishes the stable process-lifetime client contract used by all
current and future projections. Production adapter migration remains in
M2-E27 through M2-E30.
