# Jido Console Backlog

This backlog converts accepted research into 84 stable capability items. The [roadmap](../README.md) sets release order and gates. Beadwork owns implementation tasks, dependencies, assignment, and status.

Status: **planned**

## Areas

| Area | File | Main purpose |
| --- | --- | --- |
| Readiness, release, models, and semantic core | [Foundation and core](foundation-and-core.md) | Baseline evidence, distribution, model contracts, commands, events, permissions, and results |
| Session runtime and agents | [Session runtime](session-runtime.md) | One supervised owner, safe asynchronous control, and durable child-agent trees |
| Clients and protocol | [Clients and protocol](clients-and-protocol.md) | Client parity, local and remote access, identity, and versioned wire contracts |
| Durability | [Durability and recovery](durability-and-recovery.md) | Exact acceptance, one cross-store watermark, replay, resume, and audit |
| Views | [Views and TUI](views-and-tui.md) | Terminal quality, model and lane views, local workbench, and collaborative documents |
| Execution | [Executors and security](executors-and-security.md) | Restricted local work, worktree custody, isolated adapters, trusted nodes, and remote execution |
| Extension | [Extensions and live update](extensions-and-live-update.md) | Reviewed code change, recovery, and rollback |

## Use

- Use the roadmap phase as the order constraint.
- Keep each item small enough to test alone.
- Treat Gate 0 entries as readiness evidence, not as a product milestone.
- Do not create an internal-only roadmap milestone for one backlog group.
- Link an implementation issue or pull request when work starts.
- Do not close an item until its acceptance checks pass.
- Keep supporting studies out of release gates until they prove a required policy.
- Keep ownership, effort, dependencies, critical path, readiness, and proof-artifact status in Beadwork.
