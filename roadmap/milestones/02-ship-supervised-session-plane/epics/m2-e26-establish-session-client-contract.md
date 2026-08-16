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
last_updated_in: 1.1.0
---

# M2-E26: Establish the Session.Client Contract

## Goal

Define one reusable driver contract for attaching to and controlling a
supervised session.

## Scope

- Define the `Session.Client` attach and detach API.
- Define input, output, snapshot, control, and capability operations.
- Define separate send, steer, queue, remove, cancel, approve, reject, and status operations.
- Define client identity, session identity, and process-lifetime attachment
  identity.
- Define acknowledgement, gap, recovery, and bounded-delivery behavior for
  the driver API.
- Expose typed command effects, model content, view details, permission
  results, and extension-hook results through the contract.
- Add a reusable behavior and contract test suite for all client drivers.
- Keep the contract renderer-neutral and independent of client adapter code.
- Prohibit a client-adapter raw Jidoka or runtime-event stream outside this contract.
- Do not migrate the TUI, automation, text, or JSON adapters in this epic.

## Out of Scope

- Migration of any existing client adapter.
- Deletion of the old TUI-owned session or turn path.
- Application-restart recovery or durable input receipts.
- LiveView, SSH, external client deployment, or extension loading.

## Dependencies

This epic depends on M2-E16 for distinct steering and follow-up operations,
M2-E18 for delivery-gap recovery, M2-E20 for two-stage cancellation, M2-E21
for registry descriptors, M2-E22 for typed effects, M2-E23 for model and view
results, M2-E24 for permission results, and M2-E25 for extension and hook
results.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
`Session.Client` API, driver behavior contract, reusable contract suite, and
deterministic attach, detach, input, output, snapshot, control, capability,
acknowledgement, and recovery tests. It must not migrate an existing adapter.

## Acceptance Checks

- A client can attach and detach with an exact session and attachment identity.
- The contract defines input, output, snapshot, control, and capability results.
- Acknowledgements, gaps, bounded delivery, and recovery use typed results.
- A stale, repeated, or cross-session client operation fails without changing
  current session state.
- Command effects, model content, view details, permission results, and hook
  results use the same renderer-neutral contract.
- The reusable behavior suite can run against each future client driver.
- A client cannot bypass bounded delivery with a raw Jidoka or runtime-event subscription.
- No TUI, automation, text, or JSON adapter is migrated by this epic.
- Deterministic tests cover attach, detach, input, output, snapshot, control,
  capability, acknowledgement, gap, and recovery behavior.

## Proof Artifacts

- `Session.Client` API and identity schema
- Driver behavior contract
- Reusable client contract test suite
- Attach, detach, input, output, snapshot, and control results
- Acknowledgement, gap, and recovery results
- Cross-session and stale-operation rejection results

## Milestone Traceability

This epic covers the Milestone 2 requirement for one `Session.Client` contract
with attach, detach, input, output, snapshot, control, and capability APIs. It
also provides the reusable behavior suite needed before client migration.
