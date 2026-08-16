---
milestone: 3
type: release_milestone
title: Add durable resume, fork, and audit
status: proposed
depends_on: [milestone-2]
release: v0.3
introduced_in: 0.1.0
last_updated_in: 1.1.0
---

# Milestone 3: Add Durable Resume, Fork, and Audit

## Goal

Recover acknowledged session and execution state after an application restart.

## Outcome

A session can use exact resume when the Console and Jidoka records share one verified durable watermark. It can use a clearly named transcript-only mode when exact recovery is not possible.

## Delivery Policy

Milestone 3 requires production-candidate proof and an evidence-only quality
audit. Its delivery graph must not include tag, package, archive, or public
release work while publication is disabled.

## Planning Readiness

Deep planning can start before the Milestone 2 audit. Planning does not start
Milestone 3 delivery and does not permit a Milestone 2 requirement to move into
Milestone 3.

Before Milestone 3 can become `ready` or start implementation:

- Complete the Milestone 2 evidence audit and its skipped-publication record.
- Prove that every production client consumes only canonical Console protocol data through `Session.Client`.
- Prove the receiving-process mailbox and copied-payload bound with a stopped client under stream load.
- Prove attach, acknowledgement, gap, snapshot, suffix replay, detach, and reattach through the production client paths.
- Complete the live steering and follow-up queues, permission life cycle, typed effects, cancellation, and exact worker-drain contracts that Milestone 3 must classify and persist.
- Freeze the Milestone 2 protocol fixtures, semantic replay fixtures, client contract suite, and fault-isolation results as Milestone 3 compatibility inputs.

Before epic generation, deep planning must produce:

- A durable-record inventory that marks each record as authoritative, derived, durable, process-local, sensitive, or forbidden.
- The exact acknowledgement rule for input, commands, effects, events, checkpoints, and storage commits.
- A process ownership and startup-order design for the session recovery unit, runtime workers, delivery, and the supervised storage writer.
- A Console-event and Jidoka-checkpoint commit and reconciliation state machine.
- A session-generation and fencing design for stale workers, results, timers, storage replies, and client operations.
- A storage evaluation matrix with durability, ordering, migration, repair, backup, bounded-queue, latency, and crash-test criteria.
- A crash-injection matrix for the session owner, runtime controller, worker, storage writer, application, and operating-system termination points.
- An operation matrix for exact resume, transcript-only resume, retry, fork, repair, and abandon behavior.

These items are planning inputs. Generated epics and Beadwork own the resulting
implementation tasks and dependencies.

## Work

- Define the storage behavior and evaluation criteria before selecting the embedded indexed store.
- Store versioned JSON-compatible Console events, command receipts, projections, pending interactions, approvals, and schema data.
- Declare which stored records are authoritative and which projections, indexes, snapshots, and caches are derived and rebuildable.
- Keep Jidoka execution truth in Jidoka journals and checkpoints. Do not copy runtime history into Console storage.
- Define one Console-to-Jidoka durable watermark and one checkpoint-to-event identity.
- Define commit order and reconciliation for a Console event without its checkpoint and a checkpoint without its Console projection.
- Land any required additive Jidoka contract before the Console integration.
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
- Bound the storage-writer queue and apply explicit backpressure or a typed unavailable result. Do not acknowledge durable work before the storage durability contract confirms it.
- Keep storage engine work outside the semantic session-owner process and define the failure boundary between one session and the shared writer.
- Define migration, backup, repair, retention, archive, and removal behavior.
- Make fork create a new session identity at one durable boundary. Do not inherit an active unsafe effect, live approval, client attachment, or execution lease as current authority.
- Let a client attach after restart through the same `Session.Client` snapshot, sequence, gap, and recovery contract used before restart.
- Add operating-system secret-store profiles and store only credential references.

## Out of Scope

- Remote session distribution
- Multi-agent child sessions
- Browser and SSH deployment
- QuackDB as a required dependency

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
- A recovering session does not report ready, accept normal attachment, or wake execution before migration and reconciliation complete.
- The storage-writer mailbox stays within its declared bound under load and failure. Writer unavailability cannot produce a false durable acknowledgement.
- A client can attach after restart and recover through the versioned `Session.Client` contract without a raw runtime-event path.
- A fork has a new session identity and does not reuse current authority from an active unsafe effect, live approval, client attachment, or execution lease.
- Recovery time, replay count, snapshot size, and storage queue use have measured limits for the supported session-size claim.
- An incompatible schema or storage error fails explicitly without creating an empty replacement session.
- No credential value enters a file, database, event, log, trace, artifact, or protocol record.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Complete and record the v0.3-quality source milestone with durable resume,
fork, and audit. This is the first quality target with a complete continuity
claim. Do not publish a tag or package.
