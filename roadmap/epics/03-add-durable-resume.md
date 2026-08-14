---
phase: 3
title: Add durable resume, fork, and audit
status: proposed
depends_on: [2]
release: v0.3
introduced_in: 0.1.0
last_updated_in: 1.0.1
---

# Phase 3: Add Durable Resume, Fork, and Audit

## Goal

Recover acknowledged session and execution state after an application restart.

## Outcome

A session can use exact resume when the Console and Jidoka records share one verified durable watermark. It can use a clearly named transcript-only mode when exact recovery is not possible.

## Epic Breakdown

| Epic | Result |
| --- | --- |
| `P3-E1` Durable event store | Versioned indexed storage, migrations, retention, backup, and repair |
| `P3-E2` Console and Jidoka watermark | One checkpoint boundary, commit order, orphan rules, and crash reconciliation |
| `P3-E3` Durable admission and effects | Restart-safe receipts, reserved results, and safe uncertain-effect handling |
| `P3-E4` Resume, replay, retry, and fork | Distinct recovery operations with exact state claims |
| `P3-E5` Durable identity and audit | Complete model identity, trust, origin, portable audit, and credential references |

## Work

- Define the storage behavior and evaluation criteria before selecting the embedded indexed store.
- Store versioned JSON-compatible Console events, command receipts, projections, pending interactions, approvals, and schema data.
- Keep Jidoka execution truth in Jidoka journals and checkpoints. Do not copy runtime history into Console storage.
- Define one Console-to-Jidoka durable watermark and one checkpoint-to-event identity.
- Define commit order and reconciliation for a Console event without its checkpoint and a checkpoint without its Console projection.
- Land any required additive Jidoka contract before the Console integration.
- Admit restart-safe input and its idempotency receipt before the advisory execution wake-up.
- Reserve result identity, effective arguments, and replay policy before each external effect starts.
- Reconcile an uncertain unsafe effect. Never repeat it automatically.
- Define deterministic replay, exact resume, transcript-only resume, retry, and fork as different operations.
- Keep canonical history immutable and build compact model context as a supervised bounded projection.
- Persist the exact provider, model, variant, generation settings, prompt identity, tool schema, and skill schema for each durable turn.
- Preserve origin, trust, accepted workspace state, and a safe portable audit chain.
- Run the default store under the Jido home `state/` directory with one supervised writer.
- Define migration, backup, repair, retention, archive, and removal behavior.
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
- Exact resume restores the correct checkpoint, queues, approval state, model identity, and pending state.
- Transcript-only resume never claims live runtime recovery.
- Replay, retry, resume, and fork state whether they can call a model or tool.
- Prompt compaction does not remove source history used for audit, replay, or fork.
- Sessions survive an application restart under the default and an isolated `JIDO_HOME`.
- An incompatible schema or storage error fails explicitly without creating an empty replacement session.
- No credential value enters a file, database, event, log, trace, artifact, or protocol record.
- The common milestone release gate in [the roadmap index](../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.3 with durable resume, fork, and audit. This is the first release with a complete continuity claim.

## References

- [Durability and recovery backlog](../backlog/durability-and-recovery.md)
