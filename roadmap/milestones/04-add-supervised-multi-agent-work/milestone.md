---
milestone: 4
type: release_milestone
title: Add supervised multi-agent work
status: proposed
depends_on: [milestone-3]
release: v0.4
introduced_in: 1.0.0
last_updated_in: 1.0.2
---

# Milestone 4: Add Supervised Multi-Agent Work

## Goal

Make BEAM supervision and controlled concurrency visible in a reliable local coding workflow.

## Outcome

Several agents can work in parallel on named lanes with durable child identity, bounded authority, owned worktrees, explicit budgets, and deterministic acceptance or rejection.

## Work

- Add durable parent, child-agent, task, attempt, lane, and worktree identities.
- Put named lanes on cursors over one immutable session tree.
- Give each lane its own model and profile selection without a silent fallback.
- Add parent-child token, cost, time, turn, tool, depth, and concurrency budgets.
- Make child authority the strict intersection of parent policy and child policy.
- Add cancellation trees, leases, progress, queues, mailboxes, retry state, and recovery state.
- Give each coding lane one monitored owner for worktree create, file custody, state, and idempotent cleanup.
- Define exclusive and shared file-custody rules and deterministic conflict behavior.
- Define accept, reject, merge, current-run revert, and abandoned-lane policies.
- Derive available capacity from live holders or leases.
- Use the existing evaluation matrix for side-by-side model and agent comparison.
- Add fault injection for child, model, tool, executor, owner, and application restarts.

## Out of Scope

- LiveView
- Multi-user editing
- Remote agents or remote executors
- Organization identity
- Automatic merge of conflicting work

## Exit Gate

- Several agents complete useful work in parallel through the production artifact.
- One failed or cancelled child cannot corrupt its parent, peer lanes, or accepted workspace state.
- A child cannot gain a tool, credential, file root, network right, budget, depth, or capacity that its parent did not hold.
- Each lane uses its declared model and durable profile identity.
- File custody prevents undeclared cross-lane writes and reports deterministic conflicts.
- Accept, reject, merge, revert, crash, cancel, and force-kill paths leave no unowned worktree or child process.
- Parent and child budget accounting reconciles after normal completion and failure.
- Fault-injection results state recovery time, lost work, repeated work, and final accepted state.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.4 with supervised local multi-agent work and owned worktree lanes.
