---
epic: M1-E30
type: epic
title: Publish and Record Jido Console v0.1
status: deferred
milestone: milestone-1
beadwork_id: jido_console-m1e30
depends_on: [M1-E29]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.8
---

# M1-E30: Publish and Record Jido Console v0.1

## Goal

Publish the approved v0.1 payload through every required channel and record the immutable release identity.

## Delivery State

Publication is deferred until 2026-10-01. The approved Milestone 1 source
baseline can support Milestone 2 work without a public v0.1 release.

## Scope

- Bind one release pull request to the source identity and passing evidence manifest from M1-E29.
- Publish the signed direct archive, checksums, SBOM, and provenance through the protected release workflow.
- Publish the approved Homebrew formula for the same payload.
- Publish `@agentjido/jido-console` and its exact-version macOS ARM64 target package for the same payload.
- Create the immutable v0.1 source tag and public release record.
- Verify the public archive, Homebrew, and npm identities after publication.
- Link the quick start, support matrix, known limits, security boundary, and repair path from the release record.
- Record a failed or partial publication without making a complete-release claim.

## Out of Scope

- Product behavior changes.
- A new platform, channel, provider, model, or security support claim.
- Repair of a failed M1-E29 gate.
- Bypass of the protected publish workflow or its required checks.
- Durable session recovery or a later milestone claim.

## Dependencies

This epic depends on M1-E29 for the passing release decision, exact source identity, payload identity, and release evidence manifest.

## Pull Request Boundary

Deliver this epic through exactly one release pull request. The pull request binds the exact version, source, payload, and channel manifests. After merge, the protected workflow performs the production publication and writes the immutable release record. The pull request must not change product behavior or bypass a failed gate.

## Acceptance Checks

- Production publication cannot start until M1-E29 records a passing decision for the selected source identity.
- The protected workflow uses only the approved source, payload, channel manifests, and named secrets.
- The direct archive, Homebrew formula, npm entry package, and npm target package identify the same payload, version, license, checksums, and provenance.
- The immutable v0.1 tag and public release record identify the approved source and evidence manifest.
- Public install and first-run smoke checks pass for direct archive, Homebrew, npm, `npm exec`, and `npx`.
- Published output and workflow logs contain no credential or secret value.
- A partial publication produces a failed release result and the documented repair path.
- The release record does not claim durable session recovery or unsupported platform and channel cells.

## Proof Artifacts

- Release pull request.
- Protected workflow result.
- Immutable v0.1 tag and public release record.
- Public direct archive, Homebrew, and npm identities.
- Post-publication smoke-check results.
- Published support, known-limit, security, and repair links.
- Partial-publication and repair result when applicable.

## Milestone Traceability

This epic owns the Milestone 1 release effect. It publishes Jido Console v0.1 as the declared trustworthy local kernel and records the public release without a durable session-recovery claim.
