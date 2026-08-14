---
epic: M1-E24
type: epic
title: Prepare the Direct Archive Channel
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e24
depends_on: [M1-E02, M1-E03, M1-E23]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E24: Prepare the Direct Archive Channel

## Goal

Make the signed native payload installable through a direct archive on a clean
macOS ARM64 system.

## Scope

- Package the exact tested native payload from M1-E23 as a direct archive.
- Verify the archive signature and checksums before installation.
- Install and start Jido Console on clean macOS ARM64 without an existing
  Elixir or Erlang toolchain.
- Verify first run, update, and removal for the direct archive.
- Preserve the product version, license, checksums, and provenance from the
  native payload.
- Record bounded install, first-run, update, removal, and failure evidence.

## Out of Scope

- Homebrew packaging or publication.
- npm packaging or publication.
- Direct archive support for another platform or architecture.
- Installation that compiles Erlang or Elixir.
- Changes to the native payload build owned by M1-E23.
- Production publication, which M1-E30 owns.

## Dependencies

This epic depends on M1-E02, M1-E03, and M1-E23. It requires the installation
contract from M1-E02, the first-run contract from M1-E03, and the signed native
payload from M1-E23.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the direct
archive packaging and its macOS ARM64 lifecycle tests. It must not add
Homebrew or npm channel behavior.

## Acceptance Checks

- A clean supported macOS ARM64 system verifies and installs the direct
  archive.
- Installation and first run succeed without an existing Elixir or Erlang
  toolchain.
- The installed artifact reports the expected exact version and license.
- Update preserves the supported product state and verifies the new archive
  before replacement.
- Removal removes owned files and leaves the documented user data policy
  intact.
- A changed or incorrectly signed archive is rejected before installation.
- Install, first run, update, and removal evidence is redacted and reproducible.
- The direct archive uses the M1-E23 payload without recompiling or downloading
  a replacement runtime.

## Proof Artifacts

- Direct archive manifest
- Clean macOS ARM64 install result
- First-run result without an Elixir or Erlang toolchain
- Update result
- Removal result
- Signature and checksum verification results
- Redacted lifecycle evidence

## Milestone Traceability

This epic covers the direct archive cell in the v0.1 platform and channel
matrix and its install, first-run, update, and removal evidence.
