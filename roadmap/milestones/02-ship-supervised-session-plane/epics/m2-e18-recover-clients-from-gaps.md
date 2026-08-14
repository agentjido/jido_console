---
epic: M2-E18
type: epic
title: Recover Clients from Delivery Gaps
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e18
depends_on: [M2-E11, M2-E17]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E18: Recover Clients from Delivery Gaps

## Goal

Let a client recover from a delivery gap through an explicit snapshot and replay path without silently losing semantic state.

## Scope

- Define explicit gap messages with session identity, last acknowledged sequence, and current sequence.
- Provide a bounded snapshot of approved semantic session state.
- Replay an available event suffix after a snapshot when the client requests it.
- Validate snapshot and replay identities before applying them to a client projection.
- Reset client delivery state after successful recovery and resume bounded updates.
- Reject stale, cross-session, invalid-order, and malformed recovery data.
- Distinguish delivery-gap recovery from application-restart recovery and durable resume.

## Out of Scope

- Application-restart recovery
- Durable input receipts or a Console-to-Jidoka watermark
- Persistent event-log repair
- Remote client deployment
- Multi-user collaboration

## Dependencies

This epic depends on M2-E11 for semantic snapshots and replay and M2-E17 for bounded delivery and explicit gap detection.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds gap messages, snapshot and suffix replay recovery, identity checks, and focused tests. It must not claim restart-safe session recovery.

## Acceptance Checks

- A client receives an explicit gap instead of silently missing updates.
- Snapshot and suffix replay restore the same semantic state as the session owner.
- Recovery checks session identity, sequence, protocol version, and bounded data size.
- Stale, cross-session, invalid-order, and malformed recovery data is rejected.
- A recovered client resumes bounded delivery from the correct acknowledged sequence.
- A delivery gap is not described as application-restart recovery or durable resume.

## Proof Artifacts

- Gap message and recovery protocol schema
- Snapshot and suffix replay result
- Stale and cross-session recovery denial results
- Bounded recovery-size results
- Recovery limitation record for Milestone 3 durability

## Milestone Traceability

This epic completes process-lifetime client recovery from delivery gaps for the Milestone 2 session plane without taking scope from Milestone 3 durable resume.
