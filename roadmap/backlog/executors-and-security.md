# Executors and Security Backlog

## EXEC-001: Make runtime location an adapter concern

- Phase: 6
- Priority: high
- Work: Use one runtime protocol for in-process, port, isolated-service, container, attached-node, and remote-host execution.
- Acceptance: Session code does not depend on runtime location. Each adapter declares its support and trust tier.

## EXEC-002: Negotiate remote runtime compatibility

- Phase: 7
- Priority: high
- Work: Check protocol version, runtime capabilities, trust zone, file custody, and transfer rules before attachment.
- Acceptance: An incompatible runtime cannot join a session and receives a clear reason.

## EXEC-003: Narrow child authority

- Phase: 4
- Priority: high
- Work: Compose child policy with inherited policy and use the strictest limit.
- Acceptance: Delegation cannot gain tools, credentials, media, file roots, network, depth, time, turns, or child capacity.

## EXEC-004: Give each subprocess protocol one owner

- Phase: 6
- Priority: high
- Work: Put frame buffering, parsing, session identity, controls, standard error, and exit handling in one supervised process.
- Acceptance: A subprocess has one ordered state owner and one semantic callback boundary.

## EXEC-005: Supervise worktree life cycle

- Phase: 4
- Priority: high
- Work: Give worktree create, monitor, accept, reject, and idempotent cleanup operations to one owner.
- Acceptance: Normal exit, crash, cancel, force kill, accept, and reject leave no unowned worktree or inherited dirty retry state.

## EXEC-006: Derive capacity from live holders

- Phase: 4
- Priority: medium
- Work: Track model, tool, agent, runtime, and workspace holders or leases. Compute available capacity from them.
- Acceptance: Process exit releases capacity without repair of a separate free-slot counter.

## EXEC-007: Publish runtime ownership and support

- Phase: 6
- Priority: high
- Work: State who owns model loop, history, tools, hooks, context, compaction, files, controls, delivery, cleanup, and credentials for each adapter.
- Acceptance: Trust, isolation, supported behavior, and projection-only behavior are visible before use.

## EXEC-008: Graduate generated tools with evidence

- Phase: 6
- Priority: high
- Work: Build, scan, test, and identify a generated artifact in a restricted executor before trust review.
- Acceptance: The evidence binds to the exact artifact. A successful compile alone cannot grant trusted execution.

## EXEC-009: Authenticate remote runtime access

- Phase: 7
- Priority: high
- Work: Use one-time bootstrap, scoped runtime grants, short-lived connection tickets, and independent revocation.
- Acceptance: A handoff target does not contain a reusable credential, and a revoked runtime cannot continue new work.

## EXEC-010: Add a managed OTP-node executor

- Phase: 7
- Priority: high
- Work: Start a hidden node through a supervised system process, complete a bounded handshake, attach one monitored owner lease, and clean the complete node when the owner or manager stops.
- Acceptance: Startup timeout, node crash, owner crash, cancel, and normal stop leave no child or temporary state. Documentation states that distribution is a trusted boundary, not a sandbox.

## EXEC-011: Delegate credentials explicitly

- Phases: 1, 6, and 7
- Priority: high
- Work: Give each tool, child agent, node, container, and remote executor an explicit credential and environment allowlist. Resolve credentials only for the declared operation.
- Acceptance: v0.1 tools do not inherit provider credentials or the full host environment. Later adapters pass the same rule. Audit data contains references and decisions, not secret values.

## EXEC-012: Restrict v0.1 file and environment access

- Phase: 1
- Priority: high
- Work: Start coding processes with a private temporary `HOME`, an environment allowlist, and declared workspace, toolchain, artifact, and temporary roots. Reject symbolic-link escape.
- Acceptance: Host-file and canary-secret tests cannot read provider keys or undeclared files through direct, relative, absolute, or symbolic-link paths.

## EXEC-013: Restrict network and own the v0.1 process tree

- Phase: 1
- Priority: high
- Work: Deny undeclared loopback and external network access and give the complete restricted process tree one monitored owner.
- Acceptance: Network canary tests fail safely. Normal completion, rejection, cancel, timeout, owner exit, and force kill leave no child process.

## EXEC-014: Enforce file and worktree custody between lanes

- Phase: 4
- Priority: high
- Work: Define exclusive and shared file roots, ownership changes, conflict detection, merge policy, and cleanup for concurrent lanes.
- Acceptance: A lane cannot write outside its custody. Conflicting accepted changes have one deterministic stop or review path.
