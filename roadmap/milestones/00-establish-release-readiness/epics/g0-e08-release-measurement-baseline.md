---
epic: G0-E08
type: epic
title: Record the release measurement baseline
status: proposed
milestone: gate-0
depends_on: [G0-E01]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E08: Record the Release Measurement Baseline

## Goal

Record stable current measures for the production artifact without a performance claim.

## Scope

- Measure package size.
- Measure help startup, runtime readiness, first frame, and idle memory.
- Define exact measurement start and stop points.
- Record the artifact, host, toolchain, command, sample count, and summary method.
- Separate cold and warm results where they have different meanings.
- State limits and sources of measurement noise.

## Out of Scope

- Performance optimization
- A public speed or memory claim
- A general benchmark framework
- Platforms outside the current support matrix

## Dependencies

This epic depends on G0-E01 for clean artifact identity and evidence output.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the measurement method, focused checks, and the first baseline report.

## Acceptance Checks

- Each measure has one documented unit and boundary.
- Another operator can run the same command on the declared platform.
- The report identifies cold, warm, and sampled results correctly.
- Results link to the exact production artifact.
- The report does not present environment-specific data as a support claim.

## Proof Artifacts

- Measurement method
- Raw redacted result set
- Summary report
- Artifact and environment identity

## Milestone Traceability

This epic covers package size, help startup, runtime readiness, first frame, and idle-memory measures in Gate 0.
