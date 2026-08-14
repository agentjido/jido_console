---
epic: M1-E26
type: epic
title: Prepare the npm Channel
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e26
depends_on: [M1-E24]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E26: Prepare the npm Channel

## Goal

Prepare the v0.1 macOS ARM64 native release for the supported npm entry
package and exact-version target package.

## Scope

- Prepare `@agentjido/jido-console` as the supported npm entry package.
- Prepare the exact-version macOS ARM64 target package.
- Make the entry package select the declared target package for the supported
  platform and architecture.
- Verify global, local, `npm exec`, and `npx` installation and first-run
  behavior.
- Verify update and removal behavior for the supported npm lifecycle.
- Preserve the native payload version, license, checksums, and provenance.
- Keep package installation free of Erlang or Elixir compilation.
- Keep package installation free of release downloads from an install script.

## Out of Scope

- Native payload creation owned by M1-E23.
- Direct archive packaging owned by M1-E24.
- Homebrew packaging or publication.
- npm targets for unsupported platforms or architectures.
- Provider credentials or live model calls during installation tests.
- Production publication, which M1-E30 owns.

## Dependencies

This epic depends on M1-E24. It uses the verified native payload and direct
archive lifecycle contract as the npm source artifact.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the npm
entry package, exact macOS ARM64 target package, package metadata, and npm
lifecycle tests. It must not add Homebrew behavior or change the native
payload.

## Acceptance Checks

- `@agentjido/jido-console` resolves the exact supported macOS ARM64 target
  package.
- Global, local, `npm exec`, and `npx` flows install and start the expected
  exact version.
- First run succeeds without an existing Elixir or Erlang toolchain.
- Update and removal pass for the supported npm lifecycle.
- The installed artifact reports the expected version and license.
- npm installation does not compile Erlang or Elixir.
- npm installation does not download a release from an install script.
- Package checksums and provenance identify the same payload as M1-E24.
- Lifecycle evidence is redacted, repeatable, and tied to the package version.

## Proof Artifacts

- npm entry package manifest
- Exact-version macOS ARM64 target package manifest
- Global install and first-run result
- Local install and first-run result
- `npm exec` result
- `npx` result
- Update result
- Removal result
- Package checksum and provenance evidence
- Redacted npm lifecycle evidence

## Milestone Traceability

This epic covers the npm cell in the v0.1 platform and channel matrix and its
install, first-run, update, and removal evidence.
