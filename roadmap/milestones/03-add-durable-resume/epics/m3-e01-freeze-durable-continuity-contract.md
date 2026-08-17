---
epic: M3-E01
type: epic
title: Freeze the Durable Continuity Contract
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e01
depends_on: [M2-E37]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.5
---

# M3-E01: Freeze the Durable Continuity Contract

## Goal

Turn the approved Milestone 3 planning baseline into one versioned, testable durability contract before storage code starts.

## Scope

- Define the authoritative, derived, process-local, sensitive, and forbidden record classes.
- Define the durable acknowledgement rule for input, commands, Console events, Jidoka checkpoints, effects, watermarks, and client output.
- Define the exact-resume, transcript-only, retry, repair, abandon, and fork operation matrix.
- Define the session generation fence, recovery lifecycle, watermark states, crash points, file-only boundary, and hard storage limits.
- Define secret-free credential profiles, structural pre-persistence rejection,
  and final-call credential containment for Console and Jidoka data.
- Add the protocol-level durability and continuity values needed by later epics.
- Freeze the SQLite decision and the `JIDO_HOME/state/sessions/v1` layout from the planning baseline.

## Out of Scope

- Database dependencies or file I/O
- A storage behavior or writer process
- Jidoka source changes
- Session recovery implementation
- Client or renderer changes

## Dependencies

This epic depends on M2-E37. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M2-E37 has approved the exact v0.2 source and roadmap baseline.
- The frozen M2 protocol, semantic replay, client contract, and fault-isolation fixtures are available.
- The planning baseline has no unresolved ownership or acknowledgement term.

### Decisions and invariants

- Use the planning baseline as the normative v0.3 design input. A later implementation cannot weaken a durability rule without a roadmap change.
- Keep durable admission acknowledgement, Jidoka checkpoint acknowledgement, verified watermark, and process-local client acknowledgement as different values.
- Exact resume is available only from a verified Console-to-Jidoka watermark. Transcript-only mode is explicit and read-only.
- All Milestone 3 session-store files are local files under `JIDO_HOME/state/`.
  Other product-owned logs and artifacts remain in their declared locations
  below `JIDO_HOME`. No remote service or database path is part of the contract.
- Hard byte, count, queue, replay, and database limits are protocol and storage errors, not best-effort warnings.
- Jido-owned credential profiles contain stable references only. External secret sources are read only, are not resume state, and are resolved only at the final provider or tool boundary.
- Credential-bearing fields and structures fail before a receipt, event, Jidoka
  value, log, trace, artifact, or durable acknowledgement can exist. This check
  does not resolve an external credential source or compare ordinary input with
  its value.

### Delivery steps

1. Add versioned continuity, durable receipt, generation, watermark, recovery-state, and operation-result schemas.
2. Add the record-classification and acknowledgement tables to maintained product documentation.
3. Add generated validators and canonical fixtures for each new value family.
4. Add negative fixtures for forbidden runtime values, credential values, credential-shaped fields, inline authorization data, invalid modes, invalid transitions, and oversized data.
5. Freeze the crash-point and qualification-profile identifiers used by all proof epics.
6. Record the exact M2 fixture digests that become M3 compatibility inputs.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Record class | Every planned record has one owner and one class | No record has two authoritative owners |
| Acknowledgement | Each returned receipt names its commit boundary | Queued or in-memory work cannot report durable |
| Continuity mode | Exact and transcript-only results are distinct | No implicit downgrade |
| Operation safety | Each operation states whether it can call a model or tool | Unsafe work has no automatic repeat path |
| Bounds | Every list, map, text, record, queue, replay, and file class has a limit | Oversize fails before acknowledgement |
| Sensitive admission | Credential-bearing structures fail before persistence; final-call values cannot escape | Zero durable bytes or wake-up for a rejected structure |

### Completion boundary and handoff

M3-E03 and M3-E04 can start in parallel from this contract. M3-E02 is skipped.
M3-E06 owns the minimum direct-adapter proof with the production store. An
implementation pull request must return a roadmap defect instead of changing a
frozen durability or path rule.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- Every Milestone 3 record has one declared owner and durability class.
- Every acknowledgement names the exact operation that makes it durable.
- Exact resume, transcript-only resume, retry, repair, abandon, and fork have separate typed results.
- The session generation and watermark schemas contain all identities needed for stale-work rejection and reconciliation.
- The file-only layout and hard support limits match the planning baseline.
- Database pages, tree sub-budgets, WAL states, readers, writer lanes, recovery work, diagnostics, temporary data, and history pages have exact numeric limits.
- Generated values are JSON-compatible and contain no PID, reference, port, function, client, or credential value.
- A typed sensitive-value result is defined for structural input, command,
  effect, metadata, error, and opaque Jidoka rejection before persistence, and
  for final-boundary argument or result containment.
- All frozen M2 compatibility fixtures are identified by digest.
- No storage engine, recovery process, or client behavior is implemented.

## Proof Artifacts

- Durable record inventory
- Acknowledgement and operation matrices
- Generation and watermark schemas
- Crash-point inventory
- Bound and rejection fixtures
- Frozen M2 compatibility-input manifest

## Milestone Traceability

This epic converts the Milestone 3 design inputs into the stable contracts used by every storage, recovery, client, and proof epic.
