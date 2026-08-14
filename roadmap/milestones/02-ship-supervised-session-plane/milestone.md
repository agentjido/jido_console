---
milestone: 2
type: release_milestone
title: Ship the semantic and supervised session plane
status: proposed
depends_on: [milestone-1]
release: v0.2
introduced_in: 0.1.0
last_updated_in: 1.0.2
---

# Milestone 2: Ship the Semantic and Supervised Session Plane

## Goal

Make every current surface a client of one supervised, renderer-neutral session owner.

## Outcome

The TUI, automation, text, and JSON surfaces use one versioned session protocol and one ordered semantic state. A client can exit and attach again while the application and session stay alive.

This milestone combines the former semantic-core, session-owner, and client-conversion milestones. Internal stages belong in Beadwork and do not make separate releases.

## Work

- Land the additive Jidoka fixes for one async event order, request-controller cleanup, and required projection data before Console integration.
- Define a versioned semantic command, event, interaction, outcome, snapshot, replay, and control protocol.
- Project canonical Jidoka events at one boundary and preserve their runtime identities.
- Give each Console event a monotonic sequence, durability class, sensitivity class, origin, and trust data.
- Keep shared semantic state free of renderer data, PIDs, references, functions, and raw runtime structures.
- Keep model and tool work outside the session-owner process.
- Add the Console application supervisor, session registry, dynamic supervisor, and one session server for each live session.
- Make the session server the only owner of history, active runs, queues, control state, and Console event order.
- Bind actions, turns, lanes, requests, approvals, controls, and clients to exact process-lifetime identities.
- Use process-lifetime input admission before an advisory and coalescing wake-up. Do not call this restart-safe or durable admission.
- Separate active-run steering from queued follow-up input.
- Add bounded client delivery, acknowledgement, safe coalescing, explicit gaps, snapshots, and recovery.
- Add graceful cancel, force kill, and exact worker-drain contracts.
- Put commands, help, schemas, permissions, provenance, and client descriptors in one registry.
- Return typed command effects and separate concise model content from structured view details.
- Define the complete permission request and response life cycle.
- Define a small host-independent extension descriptor and one failure rule for each hook type. Do not load extensions in this milestone.
- Make the TUI, automation, text, and JSON surfaces use the same `Session.Client` contract.
- Generate protocol types and validators from one canonical schema and preserve bounded unknown data without granting authority.
- Delete the old TUI-owned session and turn path after parity passes.

## Out of Scope

- Application-restart recovery
- A durable input receipt
- LiveView, SSH, and external client deployment
- Multi-user shared documents
- Remote tool execution
- Extension loading and extension process hosting

## Exit Gate

- Jidoka emits one valid ordered stream and normal async completion leaves no request controller.
- Semantic replay produces the same transcript and outcomes as live reduction.
- Duplicate Jidoka events do not create duplicate Console events, and invalid order fails clearly.
- The TUI can exit during work and attach again while the session continues.
- TUI, automation, text, and JSON drivers pass one contract suite and observe the same ordered outcomes.
- Automation schemas, artifacts, output, and exit status stay backward-compatible.
- The old TUI-owned session path is deleted.
- A stale, repeated, or cross-session result cannot resolve current work.
- A slow or stopped client cannot cause unlimited mailbox growth and can recover after a gap.
- A client or tool-worker failure does not corrupt or cancel the session unless policy requires it.
- An authority hook fails closed, and an information-only hook failure is visible.
- The milestone states clearly that accepted input can be lost on an application crash before Milestone 3.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.2 with the canonical supervised session plane and current-client migration complete.
