---
epic: M1-E27
type: epic
title: Verify the v0.1 Channel Matrix
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e27
depends_on: [M1-E25, M1-E26]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E27: Verify the v0.1 Channel Matrix

## Goal

Prove the required v0.1 macOS ARM64 channel cells use one tested native
payload and meet the complete release lifecycle contract.

## Scope

- Verify the direct archive, Homebrew, and npm macOS ARM64 cells.
- Verify install, first run, update, and removal for every required cell.
- Compare the payload, exact version, license, checksums, and provenance across
  all required channels.
- Record the support matrix with explicit results for every required cell.
- Keep unsupported or untested platform and channel cells outside the support
  claim.
- Record failures, repair actions, and the final matrix decision.

## Out of Scope

- Changes to the native payload owned by M1-E23.
- Direct archive packaging owned by M1-E24.
- Homebrew packaging owned by M1-E25.
- npm packaging owned by M1-E26.
- Adding support claims for untested platforms, architectures, or channels.

## Dependencies

This epic depends on M1-E25 and M1-E26. Their channel results, together with
the transitive direct archive and native payload evidence, are required before
the matrix decision.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
cross-channel matrix verifier, comparison evidence, and final v0.1 support
matrix. It must not change channel packaging or add an untested support cell.

## Acceptance Checks

- The direct archive, Homebrew, and npm macOS ARM64 cells each pass install,
  first run, update, and removal checks.
- All required cells use the same tested native payload, exact version,
  license, checksums, and provenance.
- The matrix marks every required cell as pass or fail with linked evidence.
- An untested platform or channel is not shown as supported.
- A payload, version, license, checksum, or provenance mismatch fails the
  matrix check.
- The verifier reports failures with enough detail to identify the channel and
  lifecycle stage.
- The final matrix and evidence contain no credential or secret value.

## Proof Artifacts

- v0.1 platform and channel support matrix
- Cross-channel payload comparison
- Direct archive lifecycle references
- Homebrew lifecycle references
- npm lifecycle references
- Failure and repair record
- Final matrix verification report

## Milestone Traceability

This epic covers the required macOS ARM64 direct archive, Homebrew, and npm
cells in the v0.1 support matrix and provides the cross-channel evidence for
the Milestone 1 release gate.
