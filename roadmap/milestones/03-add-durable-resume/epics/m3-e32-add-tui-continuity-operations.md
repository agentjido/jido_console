---
epic: M3-E32
type: epic
title: Add TUI Continuity Operations
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e32
depends_on: [M3-E24, M3-E25, M3-E26, M3-E28]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E32: Add TUI Continuity Operations

## Goal

Let the terminal UI inspect and control durable sessions only through Session.Client.

## Scope

- Add session discovery, recovery-phase, ready-mode, blocked, capacity, and uncertainty views.
- Add explicit exact and transcript-only attach choices.
- Add retry, fork, repair, and abandon actions through typed client operations.
- Use bounded history pages for older transcript data and incremental output for live data.
- Keep drafts, cursor, scroll, terminal dimensions, paging position, and render timing client-local.
- Show when an operation can call a model or tool before confirmation.
- Preserve terminal cleanup, detach, reattach, gap recovery, and raw-path guards.
- Return a typed capability-denied result for credential-profile management and
  store-wide backup, restore, archive, retention, and removal operations that
  the TUI does not declare.

## Out of Scope

- A new visual system
- Direct database or Jidoka inspection
- Renderer-owned recovery policy
- Remote web workbench
- Automatic retry, repair, or mode fallback
- Store-wide administration and credential-profile management

## Dependencies

This epic depends on M3-E24, M3-E25, M3-E26, M3-E28. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E28 supplies restart attachment and bounded history access.
- M3-E24 through M3-E26 supply typed repair, retry, and fork operations.
- The M2 TUI uses Session.Client only and has no raw runtime path.

### Decisions and invariants

- The TUI displays recovery policy; it does not own it.
- Exact and transcript-only modes are separate user choices.
- History-page position is local renderer state and grants no session authority.
- Uncertain unsafe effects require an explicit typed action; a key press cannot bypass the policy contract.
- Terminal exit detaches the client but does not abandon or cancel durable work unless the user selects that operation.
- The TUI consumes the shared operations defined by M3-E24 through M3-E28. It
  does not wait for or own declarations from the CLI adapter epic.

### Delivery steps

1. Add durable session list and status projections.
2. Add recovery phase, exact, transcript-only, repair-required, and unavailable views.
3. Add bounded history-page loading and local page state.
4. Add typed retry, fork, repair, and abandon actions.
5. Add model/tool-call disclosure and confirmation views.
6. Add restart, stale-handle, uncertainty, capacity, unsupported-capability, detach, reattach, and cleanup tests.
7. Run PTY tests and the raw-runtime source guard.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Restart attach | Exact or transcript mode renders from canonical data | New attachment identity |
| Large history | Pages load within bounds | Local page state only |
| Uncertain effect | Explicit safe choices shown | No automatic retry |
| Detach | Session and durable work remain owned by server | Terminal cleans up |
| Raw path | Injected runtime tuple has no effect | Session.Client is sole source |
| Unsupported administration | Typed capability denial | No direct administrative call |

### Completion boundary and handoff

M3-E33 runs the common durable corpus through the TUI and compares it with automation, text, and JSON clients.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- The TUI discovers and attaches to durable sessions through Session.Client only.
- Recovery state and exact or transcript-only mode are visible.
- Older history uses bounded pages and live output stays incremental.
- Retry, fork, repair, and abandon use typed operations and disclose model or tool calls.
- Uncertain unsafe effects cannot repeat automatically.
- Renderer-local state does not enter shared or durable state.
- Detach, reattach, terminal cleanup, and PTY flows pass after restart.
- No raw Jidoka, SQLite, writer, or Session.Server path enters the TUI.
- Unsupported store-wide and credential-profile administration is explicit and
  does not appear as a nonfunctional TUI action.

## Proof Artifacts

- TUI continuity operation map
- Recovery-mode terminal transcripts
- Bounded history-page trace
- Uncertain-effect decision result
- Detach and reattach transcript
- PTY cleanup result
- Raw-path source and runtime guards

## Milestone Traceability

This epic adds durable continuity to the current terminal projection without moving ownership into the renderer.
