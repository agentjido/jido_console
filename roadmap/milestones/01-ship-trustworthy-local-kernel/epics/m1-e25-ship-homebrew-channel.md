---
epic: M1-E25
type: epic
title: Prepare the Homebrew Channel
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e25
depends_on: [M1-E24]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E25: Prepare the Homebrew Channel

## Goal

Make the v0.1 macOS ARM64 release installable and maintainable through
Homebrew.

## Scope

- Add a Homebrew formula for the exact tested payload from M1-E24.
- Verify the archive checksum before Homebrew installs it.
- Verify install and first run on clean supported macOS ARM64.
- Verify update and removal through the Homebrew lifecycle.
- Preserve the native payload version, license, checksums, and provenance.
- Record the formula revision and lifecycle evidence used for the support claim.

## Out of Scope

- Native payload creation owned by M1-E23.
- Direct archive packaging owned by M1-E24.
- npm packaging or publication.
- Homebrew support for another platform or architecture.
- A formula that builds the product from source during installation.
- Production publication, which M1-E30 owns.

## Dependencies

This epic depends on M1-E24. It uses the verified direct-archive payload and
its lifecycle contract as the Homebrew source artifact.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
Homebrew formula and its macOS ARM64 install, first-run, update, and removal
tests. It must not add npm channel behavior or change the native payload.

## Acceptance Checks

- The formula references the exact tested payload and its checksum.
- Homebrew installs the product on clean supported macOS ARM64.
- First run succeeds without an existing Elixir or Erlang toolchain.
- Update installs the declared new version and does not select an untested
  payload.
- Removal follows the documented Homebrew and user-data behavior.
- The installed artifact reports the expected version and license.
- The formula does not compile Erlang or Elixir or download a replacement
  runtime during installation.
- Lifecycle evidence is redacted, repeatable, and tied to the formula revision.

## Proof Artifacts

- Homebrew formula and revision
- Payload and checksum reference
- Clean macOS ARM64 install result
- First-run result
- Update result
- Removal result
- Redacted Homebrew lifecycle evidence

## Milestone Traceability

This epic covers the Homebrew cell in the v0.1 platform and channel matrix and
its install, first-run, update, and removal evidence.
