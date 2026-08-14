# Views and TUI Backlog

## VIEW-001: Render structured tool details

- Phase: 5
- Priority: high
- Work: Add typed diff, table, progress, diagnostic, and artifact views over structured result details.
- Acceptance: Model content stays stable when a client changes its presentation.

## VIEW-002: Add named session lanes

- Phase: 4
- Priority: high
- Work: Put parallel threads and tasks on named cursors over one immutable session tree.
- Acceptance: Lanes share history but do not move another lane's cursor, queue, or open operation.

## VIEW-003: Show origin and trust across clients

- Phase: 5
- Priority: medium
- Work: Project client origin, principal link, role, and trust level in transcript and approval views.
- Acceptance: A view explains where an operation came from and which authority accepted it. The data does not grant authority.

## VIEW-004: Use layered TUI tests

- Stage: Gate 0 and every terminal release
- Priority: high
- Work: Add reducer tests, width snapshots, terminal-emulator tests, production-artifact PTY tests, and redacted session replays.
- Acceptance: The release gate covers layout, escape sequences, input, timing, cancellation, resize, and long-session behavior.

## VIEW-005: Evaluate a native scrollback painter

- Stage: Research after Phase 2
- Priority: low
- Work: Compare full-frame paint with append, scroll, and changed-line operations.
- Acceptance: The study measures selection, search, flicker, repaint cost, and terminal compatibility.

## VIEW-006: Study renderer-neutral extension widgets

- Stage: Research after Phase 5
- Priority: low
- Work: Test a small versioned contract with semantic widget types and placements.
- Acceptance: The study does not add a plug-in system or terminal-cell data to the semantic core.

## VIEW-007: Define live thread controls

- Phase: 5
- Priority: medium
- Work: Give full clients the same send, steer, queue, remove, cancel, approve, reject, and status operations where supported.
- Acceptance: The client driver suite proves supported controls and declared fallbacks.

## VIEW-008: Add convergent shared documents

- Phase: 9
- Priority: high
- Work: Declare shared plans, workbench documents, and review notes. Select and implement one versioned operational-transformation or CRDT contract.
- Acceptance: Concurrent inserts, deletes, and replacements from at least three clients converge after different delivery orders. Private drafts stay local.

## VIEW-009: Add collaborative presence

- Phase: 9
- Priority: high
- Work: Show active users, shared-resource focus, selections, and cursors as transient client state.
- Acceptance: Join, leave, cursor, and selection updates are responsive, permission-aware, and absent from durable semantic history.

## VIEW-010: Add the TUI model and profile picker

- Phase: 1
- Priority: high
- Work: Add `/model` and `/profile` selection with support tier, capability, credential status, limits, and effective settings.
- Acceptance: The TUI shows the exact effective model before execution and cannot select a model that lacks a required feature without a clear error.

## VIEW-011: Select and compare models by lane

- Phase: 4
- Priority: high
- Work: Bind one explicit model and profile to each lane and show side-by-side result, usage, cost, latency, test, and failure data from the evaluation matrix.
- Acceptance: Each lane keeps its selected model unless an explicit operation changes it. Comparison data links to exact durable invocation identity.
