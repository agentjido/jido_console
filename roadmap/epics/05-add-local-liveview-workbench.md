---
phase: 5
title: Add the local LiveView workbench
status: proposed
depends_on: [4]
release: v0.5
introduced_in: 1.0.0
last_updated_in: 1.0.1
---

# Phase 5: Add the Local LiveView Workbench

## Goal

Add a rich local web view without adding a second source of truth or multi-user scope.

## Outcome

A loopback-only, single-user LiveView client shows and controls the same durable sessions, lanes, tools, diffs, tests, approvals, budgets, and supervision state as the terminal.

## Epic Breakdown

| Epic | Result |
| --- | --- |
| `P5-E1` Workbench projections | Renderer-neutral files, tools, diffs, review state, navigation, and actions |
| `P5-E2` Local LiveView client | Loopback-only web access through the same session client contract |
| `P5-E3` Project projection owner | One supervised owner for file, Git, diff, and review refresh work |

## Work

- Integrate reviewed Tilde semantic widget and workbench patterns without a Tilde runtime dependency.
- Add workspace navigation, file views, typed tool views, diff-hunk review, review state, palette, and shortcuts as pure state and actions.
- Keep renderer state, unsubmitted drafts, focus, selection, and viewport local to each client.
- Add LiveView as a `Session.Client` over the same snapshots, events, interactions, outcomes, and controls.
- Bind the server to loopback by default and support one local user only.
- Reuse the client driver contract and capability descriptors.
- Render structured diffs, tables, progress, diagnostics, artifacts, model data, lane state, budgets, and failure state.
- Give the terminal and web clients the same send, steer, queue, remove, cancel, approve, reject, and status controls where their descriptors claim support.
- Cache project file, Git, diff, and review projections in one supervised project owner. Do not run Git work for each subscriber update.

## Out of Scope

- Public network binding
- SSH
- Organization identity
- Multi-user presence
- CRDT or operational-transformation editing
- Shared unsubmitted drafts

## Exit Gate

- Terminal and LiveView show and control the same durable session and lane state.
- A submission or control in one client produces the same ordered outcome in the other.
- Unsubmitted input and renderer state stay local.
- The server rejects non-loopback binding unless a later remote-access mode is explicitly enabled.
- Typed tool and diff views do not parse model-facing prose.
- Real diff-hunk review binds comments and decisions to content identity, not only path and line.
- One project process, not each subscriber, owns file, Git, diff, and review refresh work.
- Browser and terminal drivers pass the shared client suite for every declared capability.
- The common milestone release gate in [the roadmap index](../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.5 with a supported local single-user LiveView workbench.

## References

- [Views and TUI backlog](../backlog/views-and-tui.md)
- [Clients and protocol backlog](../backlog/clients-and-protocol.md)
