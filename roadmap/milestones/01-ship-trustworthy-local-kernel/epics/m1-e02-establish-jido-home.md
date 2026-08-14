---
epic: M1-E02
type: epic
title: Establish the Jido Home Lifecycle
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e02
depends_on: [M1-E01]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E02: Establish the Jido Home Lifecycle

## Goal

Give all local product data one safe and predictable Jido home.

## Scope

- Add `JIDO_HOME` as the explicit home override.
- Use `~/.jido` when `JIDO_HOME` is not set.
- Define stable directories for durable state, diagnostic logs, artifacts, disposable cache, and process-local files.
- Create required directories with safe permissions.
- Define migration rules from the previous product layout.
- Define backup and restore behavior for supported home data.
- Define update behavior that keeps supported data and permissions safe.
- Define removal behavior for product files, cache, and retained user data.
- Make all local product paths resolve through the Jido home contract.

## Out of Scope

- Credential value storage or secret-store integration.
- Durable session recovery and audit storage from Milestone 3.
- Remote or shared home directories.
- Release channel packaging.

## Dependencies

This epic depends on M1-E01 for the new product identity and application name.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the home resolver, directory contract, lifecycle operations, migration behavior, and focused tests.

## Acceptance Checks

- `JIDO_HOME` selects the complete product home without changing unrelated host paths.
- The default home is `~/.jido`.
- Each stable directory has one documented owner and purpose.
- New files and directories use safe permissions and reject unsafe existing permissions.
- Migration is explicit, repeatable, and does not delete the source before verification.
- Backup and restore preserve supported data and report failures clearly.
- Update preserves supported data and does not widen permissions.
- Removal clearly separates disposable data from retained user data and requires the documented confirmation path.
- A path audit finds no local product path outside the home contract unless the path is an explicit workspace or system path.

## Proof Artifacts

- Jido home and directory contract.
- Permission and ownership test results.
- Migration, backup, update, and removal results.
- Isolated `JIDO_HOME` test result.
- Local path audit.

## Milestone Traceability

This epic covers the Milestone 1 work to establish one Jido home with `JIDO_HOME`, stable subdirectories, safe permissions, migration, backup, update, and removal rules.
