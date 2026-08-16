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
last_updated_in: 1.1.0
---

# M2-E27: Migrate the TUI to Session.Client

## Goal

Make the terminal UI a `Session.Client` of the supervised semantic session.

## Scope

- Replace TUI ownership of a Jidoka session and turn workers with the `Session.Client` contract.
- Preserve renderer-only local state, including input drafts, terminal dimensions, and cursor state.
- Support TUI detach and reattach while work continues in the session.
- Render ordered semantic events, snapshots, gaps, and outcomes through the client contract.
- Remove raw Jidoka and runtime-event input from the TUI live-render path.

## Out of Scope

- A second TUI session or turn ownership path.
- Durable input receipt or application-restart recovery.
- LiveView, SSH, and remote clients.
- Changes to automation, text, or JSON clients.

## Dependencies

This epic depends on M2-E26 for the completed `Session.Client` API and reusable behavior suite.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request migrates the TUI client only. It must not migrate another current client or add a compatibility shim for the old TUI-owned session path.

## Acceptance Checks

- The TUI uses `Session.Client` for commands, attachment, delivery, acknowledgement, snapshots, and gaps.
- The TUI can detach during active work and reattach to the same session without stopping the work.
- Input drafts, terminal dimensions, and renderer state remain local to the TUI client.
- The TUI observes the same ordered semantic outcomes after reattachment.
- The TUI live renderer consumes only canonical Console protocol data from `Session.Client`.
- TUI reducer, terminal, and cleanup tests pass.

## Proof Artifacts

- TUI-to-session client contract result.
- Detach and reattach transcript.
- Local-state isolation result.
- Ordered event and snapshot evidence.

## Milestone Traceability

This epic covers the Milestone 2 migration of the current terminal UI to `Session.Client`.
