---
epic: M1-E23
type: epic
title: Build the Signed Native Payload
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e23
depends_on: [M1-E01, M1-E05]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E23: Build the Signed Native Payload

## Goal

Build one tested macOS ARM64 native payload for Jido Console v0.1.

## Scope

- Build one native macOS ARM64 archive that includes the tested runtime and
  Jido Console release.
- Apply the approved release signature to the payload.
- Generate checksums for the payload and each release file that a user must
  verify.
- Generate a software bill of materials (SBOM) for the payload.
- Record provenance for the source, toolchain, build inputs, and build result.
- Record the exact product version, license, and release metadata in the
  payload and its evidence.
- Make generated metadata reproducible and document the allowed build
  differences.
- Store the signed payload and its verification evidence as release inputs for
  the channel epics.

## Out of Scope

- Direct archive publication.
- Homebrew formula publication.
- npm package publication.
- Channel installation, update, or removal tests.
- Support claims for platforms or channels outside macOS ARM64.

## Dependencies

This epic depends on M1-E01 and M1-E05. It requires the product identity and
release contract from M1-E01 and the approved release controls from M1-E05.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the native
payload build, signature and verification checks, checksums, SBOM, provenance,
and reproducibility evidence. It must not publish or alter a distribution
channel.

## Acceptance Checks

- A clean build produces one macOS ARM64 native payload.
- Signature verification succeeds with the approved release key and fails for
  a changed payload.
- Checksums identify the exact payload and release metadata files.
- The SBOM identifies the payload contents and their versions.
- Provenance identifies the tracked source, declared toolchain, build inputs,
  and build result without exposing credentials.
- The payload and evidence contain the same exact version and license.
- Repeated builds produce the same semantic payload and metadata, with only
  documented differences allowed.
- The result does not publish a direct archive, Homebrew formula, or npm
  package.

## Proof Artifacts

- Signed macOS ARM64 native payload
- Signature and verification result
- Checksums manifest
- Software bill of materials
- Build provenance record
- Reproducibility comparison report
- Exact version and license record

## Milestone Traceability

This epic covers the signed native release payload, checksums, SBOM,
provenance, version, license, and reproducible build evidence required by the
Milestone 1 release and common release gates.
