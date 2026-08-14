# Session Runtime Backlog

## SESSION-001: Bind asynchronous work to integrity identities

- Phase: 2
- Priority: high
- Work: Bind each delayed result, control, and approval to its session, lane, turn, step, and request.
- Acceptance: A stale, repeated, or cross-session response cannot resolve current work.

## SESSION-002: Separate steering and follow-up queues

- Phase: 2
- Priority: high
- Work: Give active-run steering and next-run input different queues and operations.
- Acceptance: A client can show, add, remove, and consume each input type without changing the other type.

## SESSION-003: Separate process-lifetime admission from wake-up

- Phase: 2
- Priority: high
- Work: Give each accepted input an identity for the life of the supervised application, then send an advisory and coalescing wake-up. Do not claim restart-safe admission.
- Acceptance: A lost or repeated wake-up does not lose or duplicate input while the application stays alive. Tests show that Phase 3 is required for application-crash recovery.

## SESSION-004: Backpressure client event delivery

- Phase: 2
- Priority: high
- Work: Bound each client stream. Define acknowledgement, safe coalescing, gap notice, and snapshot recovery.
- Acceptance: A slow or stopped client cannot cause unlimited session mailbox growth and can recover after a gap.

## SESSION-005: Make workers drainable

- Phase: 2
- Priority: medium
- Work: Track queued and active work for every asynchronous worker.
- Acceptance: Tests and shutdown can wait for one exact drain condition without time estimates.

## SESSION-006: Add two-stage cancellation

- Phase: 2
- Priority: high
- Work: Model cancel requested, saving, cancelled, and force killed. Stop new child work after cancel starts.
- Acceptance: Graceful cancel has a bound. Force kill stops the owned process tree.

## SESSION-007: Keep one session owner

- Phase: 2
- Priority: high
- Work: Make the runtime session server the only owner of history, active runs, queues, and control state.
- Acceptance: Attached clients are projections and cannot create a second session owner.

## SESSION-008: Study semantic failure-loop detection

- Stage: Research after Phase 2
- Priority: low
- Work: Evaluate bounded signatures from tool name, argument digest, and structured error data.
- Acceptance: The study shows false-positive and false-negative cases before an implementation decision.

## SESSION-009: Linearize collaborative operations

- Phase: 9
- Priority: high
- Work: Give the session server one order for accepted shared-resource operations. Track resource revision and the acknowledged revision for each client.
- Acceptance: All attached clients apply accepted operations in the same order. A no-longer-valid concurrent operation has one deterministic no-change result.

## SESSION-010: Own durable child-agent identity and life cycle

- Phase: 4
- Priority: high
- Work: Give each child agent, task, attempt, lane, mailbox, lease, and worktree a durable parent-bound identity and one supervised owner.
- Acceptance: Resume and retry cannot create an untracked duplicate child. Parent, child, and accepted workspace state remain distinct.

## SESSION-011: Apply parent budget and cancellation trees

- Phase: 4
- Priority: high
- Work: Compose token, cost, time, turn, tool, depth, concurrency, and authority limits down the child tree. Propagate graceful cancel and force kill.
- Acceptance: A child cannot widen an inherited limit. Parent and child accounting reconciles after completion, crash, and cancellation.

## SESSION-012: Recover child-agent faults without parent corruption

- Phase: 4
- Priority: high
- Work: Define retry, abandon, replace, resume, and fail-parent policy for child model, tool, process, and owner failures.
- Acceptance: Fault injection shows that one failed child cannot corrupt peers, the parent, or accepted workspace state.
