---
epic: M1-E03
type: epic
title: Control Local Process Status and Shutdown
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e03
depends_on: [M1-E01, M1-E02]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E03: Control Local Process Status and Shutdown

## Goal

Give every Console background process a visible status and a reliable shutdown path.

## Scope

- Inventory each Console background process whose lifetime extends beyond one restricted command.
- Define the status states and normal `jido` command behavior for each process.
- Define owner, startup, readiness, failure, and shutdown behavior for each process.
- Route normal shutdown through the owning supervisor or process owner.
- Stop all owned background processes on normal application shutdown and owner exit.
- Remove stale process state from the Jido home after confirmed shutdown.
- Add deterministic checks for status, shutdown, and process cleanup.

## Out of Scope

- Remote or managed process control.
- Multi-user process ownership.
- General executor adapters from Milestone 6.
- Durable process recovery after application restart.
- Operating-system child trees created by one restricted run, which M1-E17 owns.

## Dependencies

This epic depends on M1-E01 for the product command and on M1-E02 for process-local paths and state.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request defines and implements local process status and shutdown behavior. It must not add remote process control or restart recovery.

## Acceptance Checks

- Every local background process has a documented owner, status, readiness, failure, and shutdown contract.
- Normal `jido` commands report status without exposing private process identifiers or credential values.
- Shutdown is idempotent and reports a clear result when a process is already stopped.
- Normal application shutdown and background-process owner exit leave no owned background process.
- A background-process failure does not leave an unowned service process or stale active marker.
- Shutdown tests pass from a clean isolated Jido home.

## Proof Artifacts

- Local process ownership and status matrix.
- Command-level status and shutdown results.
- Supervisor and background-process cleanup results.
- Isolated home cleanup report.
- Stale-process-state audit.

## Milestone Traceability

This epic covers the Milestone 1 work to define status and shutdown behavior for each local background process and to leave no owned process after shutdown.
