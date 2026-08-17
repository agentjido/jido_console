---
milestone: 3
type: release_milestone
title: Add durable resume, fork, and audit
status: proposed
beadwork_id: jido_console-m3
depends_on: [milestone-2]
release: v0.3
introduced_in: 0.1.0
last_updated_in: 1.3.1
---

# Milestone 3: Add Durable Resume, Fork, and Audit

## Goal

Recover acknowledged session and execution state after an application restart.

## Outcome

A session can use exact resume when the Console and Jidoka records share one verified durable watermark. It can use a clearly named transcript-only mode when exact recovery is not possible.

## Delivery Policy

Milestone 3 requires production-candidate proof and an evidence-only quality
audit. Its delivery graph must not include tag, release-package,
release-archive, or public release work while publication is disabled.

## Proposed Epic Specifications

Milestone 3 has 37 proposed epic specifications loaded below the
`jido_console-m3` Beadwork parent. The complete order, dependency graph,
Beadwork load record, and one-pull-request boundaries are in the
[Milestone 3 epic index](epics/README.md).

The [planning baseline](planning-baseline.md) freezes the durable record
inventory, acknowledgement rules, file-only storage decision, process
topology, generation fence, watermark state machine, operation matrix, crash
matrix, hard growth limits, credential-profile boundary, and qualification
profile used by those specifications.

## Planning Readiness

Deep planning and proposed epic specification can finish before the Milestone
2 audit.
Planning does not start Milestone 3 delivery and does not permit a Milestone 2
requirement to move into Milestone 3.

Before Milestone 3 can become `ready` or start implementation:

- Complete the Milestone 2 evidence audit and its skipped-publication record.
- Prove that every production client consumes only canonical Console protocol data through `Session.Client`.
- Prove the receiving-process mailbox and copied-payload bound with a stopped client under stream load.
- Prove attach, acknowledgement, gap, snapshot, suffix replay, detach, and reattach through the production client paths.
- Complete the live steering and follow-up queues, permission life cycle, typed effects, cancellation, and exact worker-drain contracts that Milestone 3 must classify and persist.
- Freeze the Milestone 2 protocol fixtures, semantic replay fixtures, client contract suite, and fault-isolation results as Milestone 3 compatibility inputs.

Roadmap version 1.3.0 has produced and frozen these planning inputs:

- A durable-record inventory that marks each record as authoritative, derived, durable, process-local, sensitive, or forbidden.
- The exact acknowledgement rule for input, commands, effects, events, checkpoints, and storage commits.
- A process ownership and startup-order design for the session recovery unit, runtime workers, delivery, and the supervised storage writer.
- A Console-event and Jidoka-checkpoint commit and reconciliation state machine.
- A session-generation and fencing design for stale workers, results, timers, storage replies, and client operations.
- A storage evaluation matrix with durability, ordering, migration, repair, backup, bounded-queue, latency, and crash-test criteria.
- A crash-injection matrix for the session owner, runtime controller, worker, storage writer, application, and operating-system termination points.
- An operation matrix for exact resume, transcript-only resume, retry, fork, repair, and abandon behavior.

These inputs are in the planning baseline. The proposed epic files own the
planned implementation scope and dependencies. Their Beadwork records were
loaded early for work tracking by explicit user direction. M3-E01 remains
blocked by M2-E37. No Milestone 3 implementation epic can start until M2-E37
approves the exact source baseline and `jido_console-x5b` verifies the loaded
graph against that baseline.

## Work

- Use SQLite as the default embedded indexed store after its direct Elixir adapter passes packaging and crash qualification.
- Put the database, WAL, SHM, lock, backup, archive, quarantine, manifest, and temporary files below `JIDO_HOME/state/sessions/v1/`.
- Use one database with exact page, WAL, reader, backup, archive, work-pool, and complete-tree limits. Return a typed capacity result before durable acknowledgement.
- Keep Console JSON records and authoritative Jidoka session values in separate logical tables and behind separate public contracts.
- Store versioned JSON-compatible Console events, command receipts, projections, pending interactions, approvals, and schema data.
- Declare which stored records are authoritative and which projections, indexes, snapshots, and caches are derived and rebuildable.
- Keep Jidoka execution truth in the Jidoka session value written through the public `Jidoka.Session.Store` and transition contracts. Do not copy runtime history into Console records.
- Define one Console-to-Jidoka durable watermark and one checkpoint-to-event identity.
- Define commit order and reconciliation for a Console event without its checkpoint and a checkpoint without its Console projection.
- Land the M3-E04 public Jidoka durable-mode, recovery-selection, supported-version, codec-prefix, documentation, and conformance hardening before Console integration.
- Admit restart-safe input and its idempotency receipt before the advisory execution wake-up.
- Give each recovered session instance a durable generation or fencing identity. Reject a worker result, timer, storage reply, or client operation from an earlier generation.
- Keep a recovering session unavailable for normal attachment and execution until load, migration, reconciliation, and required repair complete.
- Reserve result identity, effective arguments, and replay policy before each external effect starts.
- Reconcile an uncertain unsafe effect. Never repeat it automatically.
- Define deterministic replay, exact resume, transcript-only resume, retry, and fork as different operations.
- Keep canonical history immutable and build compact model context as a supervised bounded projection.
- Persist the exact provider, model, variant, generation settings, prompt identity, tool schema, and skill schema for each durable turn.
- Preserve origin, trust, accepted workspace state, and a safe portable audit chain.
- Run the default store under the Jido home `state/` directory with one supervised writer.
- Prevent two application instances from writing the same Jido home.
- Use one supervised maintenance coordinator and one crash-safe external
  operation manifest for work that must stop or replace the writer-owned store.
- Bound the storage-writer queue and apply explicit backpressure or a typed unavailable result. Do not acknowledge durable work before the storage durability contract confirms it.
- Keep storage engine work outside the semantic session-owner process and define the failure boundary between one session and the shared writer.
- Keep backup, migration, restore, physical repair, archive, and destructive removal in separate one-pull-request units.
- Make fork create a new session identity at one durable boundary. Do not inherit an active unsafe effect, live approval, client attachment, or execution lease as current authority.
- Let a client attach after restart through the same `Session.Client` snapshot, sequence, gap, and recovery contract used before restart.
- Add bounded current-state snapshots and ordered history pages so a large durable session does not require an unbounded attach payload.
- Store only versioned, secret-free credential profiles and selected reference identities below `JIDO_HOME`.
- Treat host environment, private user-owned dotenv, and existing operating-system keychain items as read-only external inputs. Resolve the exact selected reference only at the final provider or tool boundary.
- Reject credential-bearing fields and structures before a receipt, event,
  Jidoka value, log, trace, artifact, or durable write exists. Do not resolve an
  external credential source to inspect ordinary input.

## Out of Scope

- Remote session distribution
- Multi-agent child sessions
- Browser and SSH deployment
- QuackDB as a required dependency
- A remote or external database service
- Durable database, backup, archive, quarantine, or temporary files outside `JIDO_HOME`
- Creating, changing, copying, backing up, restoring, archiving, exporting, or deleting an external credential value
- A new vault, cloud secret service, remote credential broker, or credential-value database

## Exit Gate

- Crash injection at every Console and Jidoka commit point loses no acknowledged event.
- Recovery repeats no unsafe effect and reports every uncertain effect for reconciliation.
- One verified watermark identifies the exact Console event and Jidoka checkpoint boundary.
- Both orphan-record cases have deterministic repair, rollback, or stop behavior.
- A repeated input or command cannot create a second receipt, event, or projection change.
- A result, timer, storage reply, or client operation from an earlier session generation cannot change recovered state.
- Exact resume restores the correct checkpoint, queues, approval state, model identity, and pending state.
- Transcript-only resume never claims live runtime recovery.
- Replay, retry, resume, and fork state whether they can call a model or tool.
- Prompt compaction does not remove source history used for audit, replay, or fork.
- Sessions survive an application restart under the default and an isolated `JIDO_HOME`.
- Store migration completes once before session recovery starts. A classified
  session does not report ready, accept normal attachment, or wake execution
  before reconciliation completes and an exact or transcript-only mode owner starts.
- The storage-writer mailbox stays within its declared bound under load and failure. Writer unavailability cannot produce a false durable acknowledgement.
- The active database and complete state tree stay within their declared hard limits. A full store cannot acknowledge new normal durable work.
- Normal database writes preserve 160 MiB of control pages. Normal tree writes
  preserve 512 MiB of maintenance space. Confirmed session removal and
  whole-image retirement have one bounded control allowance so retained data
  can be released at the normal admission ceiling. The 4 GiB hard limit remains
  fail-closed.
- A persistent reader or blocked checkpoint cannot grow the WAL beyond 384 MiB or bypass the normal-write stop at 64 MiB.
- Every database, sidecar, lock, backup, archive, quarantine, manifest, and temporary file stays under `JIDO_HOME/state/` with private permissions and no symbolic-link escape.
- A second application instance cannot write the same Jido home.
- A client can attach after restart and recover through the versioned `Session.Client` contract without a raw runtime-event path.
- A supported large session attaches with one bounded current-state snapshot and ordered bounded history access.
- A fork has a new session identity and does not reuse current authority from an active unsafe effect, live approval, client attachment, or execution lease.
- Recovery time, replay count, snapshot size, and storage queue use have measured limits for the supported session-size claim.
- An incompatible schema or storage error fails explicitly without creating an empty replacement session.
- Backup, migration, restore, and repair preserve the prior valid store until the new copy verifies.
- Archive and destructive removal have different proof, confirmation, and failure boundaries.
- A selected session cannot be removed while a retained whole-store backup or
  quarantine image contains it. Whole images retire only through a separate,
  explicit, report-bound confirmation.
- No credential value materialized by Jido enters a Jido-owned durable file,
  database, event, log, trace, artifact, protocol record, command argument, or
  durable record.
- Product data-entry surfaces accept a credential profile identity, not a credential value.
- Structural admission and declared credential-canary tests pass. The gate does
  not claim that the product can identify an arbitrary unknown secret pasted
  into ordinary prompt text.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Complete and record the v0.3-quality source milestone with bounded file-only
durable resume, fork, and audit. This is the first quality target with a
complete continuity claim. Do not publish a tag or package.
