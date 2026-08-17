---
epic: M3-E34
type: epic
title: Prove the Crash and Reconciliation Matrix
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e34
depends_on: [M3-E33]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E34: Prove the Crash and Reconciliation Matrix

## Goal

Prove every durability window, owned process failure, orphan case, and stale-generation path without changing product behavior.

## Scope

- Run deterministic fault injection at every declared Console and Jidoka commit point.
- Kill the storage writer, session owner, recovery coordinator, runtime controller, worker, and application.
- Run operating-system termination at the critical commit, orphan, watermark, unsafe-effect, backup, migration, restore, repair, archive, and removal windows.
- Record every issued durable acknowledgement before termination.
- Compare final Console and Jidoka digests, receipts, sequences, effects, generations, files, and readiness states after restart.
- Prove disk-full, permission, corruption, future-schema, and capacity failures.
- Prove both orphan cases and unsafe-effect uncertainty under repeated runs.

## Out of Scope

- Product fixes
- New production fault controls
- Changing crash outcomes or limits
- Candidate packaging
- Publication

## Dependencies

This epic depends on M3-E33. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E33 proves the complete functional workflow and supplies deterministic test seams.
- All production fault seams are test-only or injected options and cannot be enabled by normal users.
- The crash matrix in the planning baseline is complete.

### Decisions and invariants

- This is proof-only. A defect returns to its functional owner.
- Run every deterministic point for each applicable record class.
- Run 25 operating-system kill repetitions for each declared critical window:
  commit-before-reply, both orphan cases, watermark commit, unsafe-effect
  uncertainty, backup, migration, restore, physical repair, archive, and removal.
- Run persistent-reader, checkpoint-busy, normal-write-stop, control-write, reader-interrupt, and checkpoint-blocked cases at their exact WAL boundaries.
- Use stable seeds and save the acknowledgement ledger for each run.
- Equivalent semantic result and durable digest are the oracle; process timing is not.

### Delivery steps

1. Freeze the crash-matrix fixture and injection-point inventory.
2. Add harness self-tests that prove each point can be reached once.
3. Run deterministic transaction, wake-up, checkpoint, projection, watermark, effect, generation, backup, migration, restore, repair, archive, and removal failures.
4. Run owned-process and application restart cases.
5. Run the repeated operating-system kill set.
6. Run disk, permission, corruption, future-schema, and quota failures.
7. Record acknowledgement ledgers, seeds, digests, queue bounds, and final states.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Commit before reply | Same committed receipt after restart | No duplicate |
| Both orphan cases | Declared deterministic result | No false verified watermark |
| Unsafe effect | Uncertain and not repeated | Zero second external call |
| Old generation | Every delayed action rejected | Durable state unchanged |
| Storage and process failure | No lost acknowledgement or empty replacement | 25 kills for each named critical window; queue and file limits remain |
| WAL checkpoint busy | Committed work remains and new writes stop as declared | Reader and 384 MiB hard limits |

### Completion boundary and handoff

M3-E36 reruns this proof through the exact installed candidate. Any failure before then returns to the owning functional epic.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- Every declared commit and process boundary has a reproducible fault result.
- No acknowledged Console event, input, command, effect result, or watermark is lost.
- No input, command, event, projection, fork, or receipt is duplicated.
- Both orphan cases reach their declared deterministic result.
- No uncertain unsafe effect repeats automatically.
- Every old-generation worker, timer, reply, recovery result, and client operation is rejected.
- Writer queue, copied payload, database, WAL, and state-tree limits hold during failure.
- Backup, migration, restore, repair, archive, and removal failures preserve their declared authority and evidence boundary.
- All repeated operating-system kill runs produce the same semantic result.
- No product behavior is changed.

## Proof Artifacts

- Versioned crash matrix
- Fault-injection inventory and harness self-test
- Acknowledgement ledgers and deterministic seeds
- Orphan and unsafe-effect results
- Owned-process and operating-system kill results
- Disk, permission, corruption, schema, and capacity results
- Post-restart digest comparisons

## Milestone Traceability

This epic satisfies the Milestone 3 crash-injection and no-unsafe-repeat exit gates.
