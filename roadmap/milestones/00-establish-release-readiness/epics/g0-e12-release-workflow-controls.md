---
epic: G0-E12
type: epic
title: Harden the release workflow controls
status: proposed
milestone: gate-0
depends_on: []
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E12: Harden the Release Workflow Controls

## Goal

Make release workflow inputs and publish gates explicit and safe.

## Scope

- Pin each release workflow dependency to an immutable identity.
- Give each workflow the minimum permissions.
- Replace inherited secrets with named required secrets or no secrets.
- Define the approved dependency update process.
- Require a passing release evidence manifest for the selected source identity before production publish.
- Prevent production publish when a required check is skipped, absent, or failed.
- Add controlled negative tests or a policy check for the publish guard.

## Out of Scope

- A production publish
- A public release
- A new platform or distribution channel
- Product implementation work

## Dependencies

This epic has no Gate 0 dependency. It defines the controls before release or publish work starts.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request changes workflow policy and its tests only. It must not publish an artifact.

## Acceptance Checks

- Reusable workflow and action references use immutable identities.
- Workflows do not use unrestricted secret inheritance.
- Workflow permissions are explicit and use the minimum access.
- A skipped, absent, cancelled, or failed required check blocks production publish.
- A missing, invalid, stale, or non-passing release evidence manifest for the selected source identity blocks production publish.
- A policy test proves the negative cases without a real publish.
- The update process retains review and test gates.

## Proof Artifacts

- Workflow dependency inventory
- Permission and secret inventory
- Publish-gate policy results
- Negative-case test results
- Dependency update procedure

## Milestone Traceability

This epic covers pinned release dependencies, limited inherited secrets, and the required-test publish guard in Gate 0.
