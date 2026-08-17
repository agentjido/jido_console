---
epic: M3-E24
type: epic
title: Add Session Repair and Abandon Operations
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e24
depends_on: [M3-E16, M3-E20, M3-E21, M3-E23]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E24: Add Session Repair and Abandon Operations

## Goal

Resolve only supported session faults, or abandon unsafe work while preserving its audit record.

## Scope

- Define the renderer-neutral Session.Client request and result contracts for
  semantic repair, reconciliation, and abandon before any client adapter uses them.

- Define a dry-run session repair plan for supported watermark, derived-state, projection, and metadata faults.
- Use M3-E20 physical repair only through its verified staged interface.
- Append semantic reconciliation and repair decisions without rewriting canonical history.
- Require explicit confirmation for any repair that changes authoritative session status.
- Add abandon for uncertain, blocked, or unrecoverable work.
- Prevent abandoned work from waking, resuming, approving, retrying automatically, or acquiring execution authority.
- Record operator intent, affected identities, old and new status, and evidence digest.

## Out of Scope

- Fabricating a Jidoka checkpoint or result
- Automatic repair of authoritative corruption
- Retry or fork
- Client user interface
- Database migration or backup mechanics

## Dependencies

This epic depends on M3-E16, M3-E20, M3-E21, M3-E23. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E16 classifies both orphan cases and exact watermark faults.
- M3-E20 provides verified physical inspection and repair primitives.
- M3-E21 provides explicit repair-required and unavailable states.
- M3-E23 provides read-only transcript access for degraded sessions.

### Decisions and invariants

- Repair is allowed only for a listed deterministic case with a complete precondition check.
- Canonical records remain immutable. A repair appends a decision and new derived or link data.
- Physical corruption repair and semantic session repair are separate operations with one coordinated result.
- Abandon preserves audit and blocks future automatic execution.
- An uncertain unsafe effect cannot be marked completed without external reconciliation evidence.

### Delivery steps

1. Add repair-plan, repair-result, confirmation, and abandon schemas.
2. Map supported recovery faults to deterministic actions.
3. Integrate physical repair through the stopped-writer staged interface.
4. Append semantic repair and abandonment events.
5. Fence each action by generation, operation ID, current status, and confirmation.
6. Add repeated, stale, cross-session, unsupported, partial, and crash tests.
7. Add post-repair and post-abandon restart verification.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Dry run | Plan lists exact reads, writes, files, and consequences | No mutation |
| Supported repair | New state verifies and audit event commits | Original evidence retained |
| Unsupported fault | Typed denial | No best-effort mutation |
| Abandon | Session becomes non-executable and inspectable | Audit history retained |
| Crash or repeat | Old or new complete result; exact retry is idempotent | No duplicate decision |

### Completion boundary and handoff

M3-E25 can create new retry work only after these states permit it. M3-E26 uses repair and abandonment status when it validates a fork source.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can grant old or undeclared authority. Check identity and mode before each mutation.
- A recovery test can hide a model or tool call. Use provider and tool probes that fail on any unexpected call.

## Acceptance Checks

- Each supported repair has a deterministic dry-run plan and exact preconditions.
- Unsupported or authoritative corruption is not repaired automatically.
- Repair appends evidence and does not rewrite canonical history.
- Physical replacement preserves the prior store until verification.
- Abandon makes the session non-executable while preserving transcript and audit data.
- An uncertain unsafe effect cannot become completed without valid reconciliation evidence.
- Repair and abandon are generation-fenced, idempotent, and crash-safe.
- Post-operation restart reaches the documented stable state.

## Proof Artifacts

- Session repair operation matrix
- Dry-run plans
- Physical and semantic repair results
- Unsupported-fault denial fixtures
- Abandon authority-denial result
- Repair and abandon crash traces

## Milestone Traceability

This epic supplies the explicit repair and abandon behavior named in the Milestone 3 operation matrix.
