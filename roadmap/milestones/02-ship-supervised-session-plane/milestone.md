---
milestone: 2
type: release_milestone
title: Ship the semantic and supervised session plane
status: proposed
depends_on: [milestone-1]
release: v0.2
introduced_in: 0.1.0
last_updated_in: 1.1.0
---

# Milestone 2: Ship the Semantic and Supervised Session Plane

## Goal

Make every current surface a client of one supervised, renderer-neutral session owner.

## Outcome

The TUI, automation, text, and JSON surfaces use one versioned session protocol and one ordered semantic state. A client can exit and attach again while the application and session stay alive.

This milestone combines the former semantic-core, session-owner, and client-conversion milestones. Internal stages belong in Beadwork and do not make separate releases.

## Delivery Baseline

Milestone 2 starts from the approved Milestone 1 source baseline on `main`.
Deferred public v0.1 publication in M1-E30 does not block Milestone 2 source
work.

## Delivery Policy

Milestone 2 is a source-quality milestone. Production-candidate proof and the
evidence audit are required. Publication is intentionally skipped. M2-E35
records this decision and does not create a tag, package, archive, or public
release.

## Generated Epics

The [Milestone 2 epic index](epics/README.md) splits this milestone into 35 epics. Each epic is the scope for exactly one pull request.

## Work

- Land the additive Jidoka fixes for one async event order, request-controller cleanup, and required projection data before Console integration.
- Define a versioned semantic command, event, interaction, outcome, snapshot, replay, and control protocol.
- Project canonical Jidoka events at one boundary and preserve their runtime identities.
- Route every client-visible live update through the canonical Console boundary. Do not send raw Jidoka or runtime events to a client.
- Give each Console event a monotonic sequence, durability class, sensitivity class, origin, and trust data.
- Keep shared semantic state free of renderer data, PIDs, references, functions, and raw runtime structures.
- Keep model and tool work outside the session-owner process.
- Add the Console application supervisor, session registry, dynamic supervisor, and one session server for each live session.
- Make the session server the only owner of history, active runs, queues, control state, and Console event order.
- Bind actions, turns, lanes, requests, approvals, controls, and clients to exact process-lifetime identities.
- Use process-lifetime input admission before an advisory and coalescing wake-up. Do not call this restart-safe or durable admission.
- Separate active-run steering from queued follow-up input.
- Add bounded client delivery, acknowledgement, safe coalescing, explicit gaps, snapshots, and recovery. Bound the receiving process mailbox and copied payload data, not only sender delivery state.
- Use ordered semantic updates for normal live delivery. Use a full snapshot for attach or explicit recovery, not for each ordinary update.
- Add graceful cancel, force kill, and exact worker-drain contracts.
- Put commands, help, schemas, permissions, provenance, and client descriptors in one registry.
- Return typed command effects and separate concise model content from structured view details.
- Define the complete permission request and response life cycle.
- Define a small host-independent extension descriptor and one failure rule for each hook type. Do not load extensions in this milestone.
- Make the production TUI, automation, text, and JSON paths use the same `Session.Client` contract without an adapter-specific runtime-event path.
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
- No current client consumes a raw Jidoka or runtime event. All live projections consume canonical Console protocol data through `Session.Client`.
- The TUI can exit during work and attach again while the session continues.
- The production TUI, automation, text, and JSON paths pass one contract suite and observe the same ordered outcomes.
- Automation schemas, artifacts, output, and exit status stay backward-compatible.
- The old TUI-owned session path is deleted.
- A stale, repeated, or cross-session result cannot resolve current work.
- A slow or stopped receiving process stays within the declared mailbox and payload-memory bound, and it can recover after a gap.
- Every client-bound live message uses the bounded delivery path. Ordinary updates do not send repeated full snapshots.
- A client or tool-worker failure does not corrupt or cancel the session unless policy requires it.
- An authority hook fails closed, and an information-only hook failure is visible.
- The milestone states clearly that accepted input can be lost on an application crash before Milestone 3.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Record a quality-approved v0.2 source milestone with the canonical supervised
session plane and current-client migration complete. Do not publish a tag or
package.
