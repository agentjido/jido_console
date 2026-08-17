---
epic: M3-E16
type: epic
title: Verify Console-to-Jidoka Watermarks
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e16
depends_on: [M3-E05, M3-E10, M3-E11, M3-E15]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E16: Verify Console-to-Jidoka Watermarks

## Goal

Create the one verified durable boundary that joins Console session truth to Jidoka execution truth.

## Scope

- Persist reserved, Jidoka-committed, Console-committed, verified, repair-required, and abandoned watermark states.
- Link Console session, generation, sequence, event, and chain digest to Jidoka session, revision, request, lease, snapshot, and value digest.
- Consume the committed Jidoka transition receipt formed by the Console-owned SQLite store callback after commit.
- Verify both sides from committed storage before advancing the watermark.
- Recreate a missing Console projection only from the qualified deterministic Jidoka source data.
- Classify a Console execution projection without a matching Jidoka checkpoint as exact-resume unavailable.
- Keep valid Console-only records after the watermark, such as accepted unstarted input and audit decisions.
- Make every repair transition idempotent and append-only.

## Out of Scope

- Startup recovery orchestration
- Exact or transcript-only resume API
- Physical database repair
- Client attachment
- Effect retry

## Dependencies

This epic depends on M3-E05, M3-E10, M3-E11, M3-E15. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E05 supplies stable public Jidoka identity and store data.
- M3-E10 supplies immutable Console events and chain heads.
- M3-E11 supplies durable accepted input state.
- M3-E15 supplies effect reservation and uncertainty state.

### Decisions and invariants

- A verified watermark commits last and is immutable.
- Exact resume reads only a verified watermark. Reserved or one-sided state cannot authorize execution.
- A Jidoka checkpoint without Console projection can be repaired only by deterministic projection with the original identities.
- A Console execution result without matching Jidoka truth is never promoted. Reconciliation appends a decision.
- Console sequence can be later than the watermark only for declared Console-only records.
- Do not use `:on_durable_checkpoint` or reconstruct a cleared terminal lease from a terminal session value.

### Delivery steps

1. Add watermark records, indexes, and state transitions.
2. Add exact cross-table identity and digest verification.
3. Join the committed SQLite store-transition receipt with the Console projection commit identity.
4. Add idempotent projection repair for the checkpoint-only case.
5. Add exact-resume denial and repair-required state for the Console-only execution case.
6. Add mismatch, duplicate, late, stale-generation, and valid-tail tests.
7. Inject crashes between each state transition and final verification.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Both sides match | One verified watermark commits | Exact identities and digests |
| Jidoka only | Deterministic projection fills the gap or repair is required | No model or tool call |
| Console execution only | Exact resume remains unavailable | Original event retained |
| Mismatch | Repair-required result | No watermark advance |
| Valid Console tail | Accepted unstarted and audit records remain | Last verified execution boundary unchanged |

### Completion boundary and handoff

M3-E17 backs up these records, M3-E20 verifies physical repair, and M3-E21 uses only verified watermarks during startup.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- One verified watermark identifies the exact Console and Jidoka boundary.
- A one-sided or mismatched state cannot become verified.
- Jidoka-only projection repair is deterministic, idempotent, and provider-free.
- A Console execution projection without Jidoka truth cannot authorize exact resume.
- Both orphan cases have a typed stop, repair, rollback, or transcript-only result.
- Valid Console-only records can exist after the watermark without creating a false execution claim.
- Watermark transitions are generation-fenced and append-only.
- Watermark code uses no undocumented checkpoint hook or private Jidoka execution module.
- Crash injection at every transition loses no acknowledged record.

## Proof Artifacts

- Watermark schema and state machine
- Cross-store identity and digest verification
- Jidoka-only repair result
- Console-only denial result
- Mismatch and stale-generation fixtures
- Commit-point crash traces

## Milestone Traceability

This epic implements the shared durable watermark and both orphan-record rules in the Milestone 3 goal.
