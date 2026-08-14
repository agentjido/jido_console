---
epic: M1-E20
type: epic
title: Require Consent for Boundary-Changing Fallback
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e20
depends_on: [M1-E09, M1-E19]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E20: Require Consent for Boundary-Changing Fallback

## Goal

Prevent a fallback from changing a provider, data boundary, cost class, or capability without explicit consent.

## Scope

- Consume the typed consent-required result from M1-E09 for a proposed boundary-changing fallback.
- Stop the turn before the boundary-changing fallback is applied.
- Show the proposed change in a redacted consent request.
- Record the user's explicit consent or rejection.
- Apply a fallback only after consent for the exact proposed change.
- Keep rejection safe and visible in CLI, TUI, and automation paths.

## Out of Scope

- Exact effect approval.
- Fallback boundary classification from M1-E09.
- Credential storage.
- Automatic provider selection without a support contract.
- Durable session recovery.

## Dependencies

This epic depends on M1-E09 for the typed consent-required result and M1-E19 for the TUI selection and effective-setting contract.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds consent display, consent records, exact-decision application, and deterministic accept/reject tests. It must not redefine fallback boundary classification.

## Acceptance Checks

- A provider, data-boundary, cost-class, or capability change cannot occur without consent.
- Consent identifies the current and proposed boundary without exposing credential values.
- Consent applies only to the exact proposed fallback.
- Rejection leaves the selected model and profile unchanged.
- A stale, repeated, or mismatched consent cannot authorize a different fallback.
- CLI, TUI, and automation paths use the same consent result contract.
- A no-change fallback does not create an unnecessary consent request.

## Proof Artifacts

- Consent-required result consumption matrix.
- Redacted consent request and response records.
- Accept and reject results for each boundary type.
- Mismatched-consent denial result.
- CLI, TUI, and automation contract results.

## Milestone Traceability

This epic covers the Milestone 1 requirement that fallback cannot change provider, data boundary, cost class, or capability without user consent.
