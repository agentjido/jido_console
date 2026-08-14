---
epic: M2-E12
type: epic
title: Add the Session Supervision Topology
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e12
depends_on: [M2-E04, M2-E10]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E12: Add the Session Supervision Topology

## Goal

Start and stop local semantic sessions through one explicit, supervised application topology.

## Scope

- Add the Console application supervisor for session infrastructure.
- Add a safe named session registry without creating atoms from untrusted session IDs.
- Add a dynamic supervisor for one temporary session server per live session.
- Define session startup, readiness, failure, normal stop, and owner-exit behavior.
- Make concurrent requests for one session resolve to one server.
- Remove session processes and stale registry state after termination.
- Keep the topology local and process-lifetime only.

## Out of Scope

- Session state ownership and event reduction
- Restart-safe session recovery
- Durable input receipts or durable watermarks
- Remote or multi-user supervision
- Managed executors

## Dependencies

This epic depends on M2-E04 for generated lifecycle protocol types and on M2-E10 for the renderer-neutral session state definition.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the application supervisor, registry, dynamic supervisor, lifecycle contracts, and focused tests. It must not implement client delivery or restart recovery.

## Acceptance Checks

- The application supervisor starts the registry and dynamic session supervisor in a documented order.
- One live session ID maps to one supervised session server.
- Concurrent session startup does not create duplicate owners.
- Untrusted session IDs do not become dynamic atoms.
- Normal stop, owner exit, and session crash remove the session process and registry entry.
- Process-lifetime behavior is clearly separated from application-restart recovery.

## Proof Artifacts

- Supervision tree and ownership diagram
- Session registry identity rules
- Startup and concurrent-attach results
- Normal-stop and crash-cleanup results
- Process-lifetime limitation record

## Milestone Traceability

This epic supplies the supervised topology required before the session server can own live semantic state and client delivery.
