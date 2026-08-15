---
epic: G0-E12
type: epic
title: Harden the release workflow controls
status: proposed
milestone: gate-0
beadwork_id: jido_console-g0e12
depends_on: []
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.5
---

# G0-E12: Harden the Release Workflow Controls

## Goal

Make the current workflow dependencies explicit and keep release work out of normal CI.

## Scope

- Pin each reusable workflow dependency to an immutable identity.
- Give each workflow the minimum permissions.
- Remove inherited secrets.
- Define the approved dependency update process.
- Verify that normal CI does not run the release audit, upload its result, or publish a release.
- Require a separate, deny-by-default publish guard when a future milestone adds publication.

## Out of Scope

- A production publish
- A production publish workflow
- A public release
- A new platform or distribution channel
- Product implementation work

## Dependencies

This epic has no Gate 0 dependency. It defines the controls before release or publish work starts.

## Pull Request Boundary

The change pins and narrows the existing CI and review workflows. It does not add a release workflow.

## Acceptance Checks

- Reusable workflow and action references use immutable identities.
- Workflows do not inherit secrets.
- Workflow permissions are explicit and use the minimum access.
- Normal CI does not run `mix jido.release.audit` or upload its local result.
- No workflow in this repository publishes a release.
- The policy check rejects a release audit, upload, or publish operation in the current workflows.
- The update process retains review and test gates.

## Proof Artifacts

- Workflow dependency inventory
- Permission and secret inventory
- Workflow policy result
- Dependency update procedure

## Milestone Traceability

This epic covers pinned release dependencies, limited inherited secrets, and the required-test publish guard in Gate 0.
