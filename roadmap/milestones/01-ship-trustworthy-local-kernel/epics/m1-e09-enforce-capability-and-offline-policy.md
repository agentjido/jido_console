---
epic: M1-E09
type: epic
title: Enforce Capability and Offline Policy
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e09
depends_on: [M1-E06, M1-E07, M1-E08]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E09: Enforce Capability and Offline Policy

## Goal

Block unsupported model work before execution and make offline mode deny every model network call.

## Scope

- Preflight every turn against the required features and the validated model catalog entry.
- Return an exact reason when a required capability is missing, unsupported, unavailable, or blocked.
- Enforce offline mode before any model network call or provider credential use.
- Record the effective model, profile, required features, policy decision, and reason.
- Classify a fallback that changes provider, data boundary, cost class, or capability as consent-required and block it until M1-E20 supplies a matching decision.
- Test policy behavior with deterministic provider and network doubles.

## Out of Scope

- Provider-specific support qualification
- Adding new model catalog entries
- Silent model or provider fallback
- Consent collection and fallback application from M1-E20
- General network sandbox implementation
- Remote execution policy

## Dependencies

This epic depends on M1-E06 for model capabilities, M1-E07 for provider contract results, and M1-E08 for credential and provider access controls.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds capability preflight, offline denial, fallback boundary classification, and focused tests. It must not collect consent, apply a fallback, or claim that a provider is supported.

## Acceptance Checks

- A required unsupported feature fails before a model turn starts.
- The failure names the exact model, feature, and reason.
- Offline mode produces no model network call and does not resolve or expose a provider credential unnecessarily.
- A boundary-changing fallback returns a consent-required decision and does not run without a matching decision.
- Policy results identify the effective model and settings.
- Deterministic tests cover supported, missing, unsupported, offline, and consent-required cases.

## Proof Artifacts

- Capability preflight decision table
- Offline network-denial results
- Fallback boundary-classification results
- Effective model and policy decision examples

## Milestone Traceability

This epic enforces model capability and offline policy. It also supplies the boundary classification that M1-E20 uses for the Milestone 1 fallback-consent gate.
