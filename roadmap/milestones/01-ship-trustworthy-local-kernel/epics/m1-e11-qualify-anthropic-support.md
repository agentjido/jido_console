---
epic: M1-E11
type: epic
title: Qualify Anthropic Support
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e11
depends_on: [M1-E07, M1-E08, M1-E09]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E11: Qualify Anthropic Support

## Goal

Qualify the declared Anthropic models for the exact v0.1 capabilities and limits that Jido Console supports.

## Scope

- Select the Anthropic models and capabilities covered by the v0.1 support claim.
- Run the provider contract harness for each declared model and capability.
- Verify credential resolution, capability preflight, offline denial, cancellation, timeout, usage, cost, prompt-cache, and error behavior.
- Record exact model identities, contract versions, results, known gaps, and support limits.
- Publish the Anthropic support evidence in the model catalog and release evidence set.

## Out of Scope

- Anthropic models without declared contract evidence
- A general provider abstraction redesign
- Silent model fallback
- Changes to credential storage or diagnostics
- Support for later releases

## Dependencies

This epic depends on M1-E07 for provider contract results, M1-E08 for credential controls, and M1-E09 for capability and offline policy.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds Anthropic-specific qualification records, fixtures, and focused checks. It must not change another provider's support claim.

## Acceptance Checks

- Each claimed Anthropic model has passing evidence for every claimed capability.
- A missing, failed, or blocked contract keeps the model out of the supported tier.
- Credential values are absent from all qualification output and artifacts.
- Offline mode blocks Anthropic model network calls.
- Capability preflight and fallback consent rules pass for Anthropic models.
- Known gaps and limits are visible beside each support claim.

## Proof Artifacts

- Anthropic model qualification matrix
- Contract harness results and source identities
- Credential and offline-policy results
- Known-gap and support-limit record

## Milestone Traceability

This epic provides the Anthropic support evidence for the Milestone 1 provider and model exit gates.
