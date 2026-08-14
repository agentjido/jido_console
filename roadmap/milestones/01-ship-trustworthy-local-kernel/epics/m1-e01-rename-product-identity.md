---
epic: M1-E01
type: epic
title: Rename the Product Identity and Preserve Interfaces
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e01
depends_on: [G0-E15]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E01: Rename the Product Identity and Preserve Interfaces

## Goal

Make `jido_console` the product, package, application, and namespace identity while keeping the user-facing `jido` command stable.

## Scope

- Rename the repository and package identity to `jido_console`.
- Rename the OTP application to `:jido_console`.
- Rename the main namespace to `Jido.Console`.
- Update build, release, package, documentation, and test references that must use the new identity.
- Keep the `jido` command name.
- Preserve the current command, automation, JSONL, artifact, signal, and exit-status contracts.
- Add compatibility checks for the preserved interfaces.

## Out of Scope

- New model, provider, credential, or execution behavior.
- Jido home storage rules.
- Changes to the Jidoka runtime.
- Changes to the user-facing command grammar.

## Dependencies

This epic depends on G0-E15, which authorizes Milestone 1 work after the Gate 0 exit audit.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request changes the product identity and proves the preserved interfaces. It must not add a new Milestone 1 feature.

## Acceptance Checks

- The project builds and starts with package identity `jido_console` and OTP application `:jido_console`.
- Production modules use the `Jido.Console` namespace where the product namespace is required.
- The installed executable remains named `jido`.
- Existing command, automation, JSONL, artifact, signal, and exit-status contract tests pass without an unapproved format change.
- Release metadata and documentation do not claim the old product identity.
- No production path depends on a stale `jido_cli` application or namespace identity.

## Proof Artifacts

- Clean build and application-start result.
- Product identity and namespace inventory.
- Preserved interface contract results.
- Release metadata and executable identity result.
- Stale-identity scan result.

## Milestone Traceability

This epic covers the Milestone 1 work to rename the repository, package, OTP application, and namespace while preserving the `jido` command and current automation interfaces.
