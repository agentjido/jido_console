---
epic: M3-E26
type: epic
title: Add Durable Session Fork
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e26
depends_on: [M3-E14, M3-E16, M3-E22, M3-E23, M3-E24]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E26: Add Durable Session Fork

## Goal

Create a new session at one durable boundary without transferring live authority.

## Scope

- Define the renderer-neutral Session.Client fork request and result contract
  before any client adapter uses it.

- Add idempotent child-session reservation and hidden partial-child state.
- Support exact fork from a verified forkable Jidoka snapshot.
- Support transcript-only fork from a validated Console history boundary.
- Create new Console session, Jidoka session when applicable, generation, audit root, and lineage identities.
- Preserve parent, root, source event, source checkpoint, workspace, and manifest provenance.
- Transfer only declared immutable history and completed safe effect evidence.
- Complete or abandon partial cross-namespace forks deterministically.

## Out of Scope

- Multi-agent child sessions
- Worktree creation or file custody
- Active effect, approval, lease, attachment, queue, or client transfer
- Arbitrary history editing
- Remote fork

## Dependencies

This epic depends on M3-E14, M3-E16, M3-E22, M3-E23, M3-E24. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E14 provides exact durable turn and workspace identity.
- M3-E16 provides verified watermark boundaries.
- M3-E22 and M3-E23 define the two source continuity modes.
- M3-E24 classifies repaired, uncertain, and abandoned sources.
- The Jidoka fork contract passes through M3-E05.

### Decisions and invariants

- A fork source is immutable and remains unchanged.
- Exact fork needs a verified watermark and Jidoka forkable snapshot. Transcript-only fork does not claim Jidoka continuity.
- The child is hidden until its Console and Jidoka records both verify.
- Client attachments, delivery acknowledgements, workers, leases, approvals, unsafe effects, timers, and executable queued input never transfer.
- Repeated fork with the same key returns the same child identity.

### Delivery steps

1. Add fork request, reservation, lineage, child-genesis, and completion schemas.
2. Validate exact and transcript-only source boundaries.
3. Reserve final child identities before cross-namespace work.
4. Create the Jidoka fork when exact mode applies.
5. Create Console lineage, genesis, and initial watermark or transcript boundary.
6. Verify the child and make it attachable.
7. Add partial-failure, repeat, stale, authority-transfer, and parent-unchanged tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Exact fork | New child has verified Jidoka and Console boundary | Source unchanged |
| Transcript fork | New read-only Console child | No Jidoka continuity claim |
| Exact repeat | Same key returns same child | No second lineage |
| Partial failure | Same reservation completes or abandons | Child stays hidden |
| Authority transfer | All live authority is absent | New generation and attachments required |

### Completion boundary and handoff

M3-E29 uses fork lineage to protect retained ancestry. M3-E31 and M3-E32 expose the two fork modes without adding multi-agent behavior.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- Each fork has a new Console session identity, generation, audit root, and lineage.
- An exact fork also has a new Jidoka session identity at one verified safe snapshot.
- A transcript-only fork makes no execution-continuity claim.
- The source remains unchanged.
- No active unsafe effect, live approval, client attachment, lease, timer, worker, or executable queue transfers.
- A partial child is not attachable and has deterministic completion or abandonment.
- Repeated fork returns the same child identity.
- Fork lineage is retained for audit and later retention decisions.

## Proof Artifacts

- Fork reservation and lineage schemas
- Exact and transcript-only fork results
- Parent-unchanged result
- Authority-transfer denial matrix
- Partial-failure recovery result
- Idempotent repeat result

## Milestone Traceability

This epic delivers durable fork while keeping Milestone 4 multi-agent work out of scope.
