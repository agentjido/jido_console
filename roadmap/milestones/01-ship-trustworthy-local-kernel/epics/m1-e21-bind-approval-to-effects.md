---
epic: M1-E21
type: epic
title: Bind Approval to Exact Effects
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e21
depends_on: [M1-E05, M1-E13, M1-E15, M1-E16, M1-E17]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E21: Bind Approval to Exact Effects

## Goal

Make an approval valid only for the exact effect and normalized parameters that the user reviewed.

## Scope

- Define one stable effect identity for each approval request.
- Normalize effect parameters before approval.
- Include the normalized parameters in the approval binding.
- Reject an approval for a different effect, workspace, run, or parameter set.
- Reject approval replay after the effect has completed, failed, or changed.
- Keep approval records free of credential values and raw secret content.
- Return a clear denial when the approval identity is stale, repeated, or mismatched.

## Out of Scope

- Provider fallback consent.
- General network or file policy changes.
- Durable approval recovery after application restart.
- Trust gained from a successful compile or test.

## Dependencies

This epic depends on M1-E05 for the Jidoka policy contract, M1-E13 for the effective restricted profile, M1-E15 for file-boundary identity, M1-E16 for network-boundary identity, and M1-E17 for process ownership.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds effect identity, parameter normalization, approval binding, replay denial, and focused tests.

## Acceptance Checks

- Every approval request has one stable effect identity.
- Normalized parameters are part of the approval identity.
- An approval for another effect, run, workspace, or parameter set is rejected.
- Replaying a completed or consumed approval is rejected.
- A changed file root, network rule, process owner, or execution profile invalidates the approval.
- Approval records contain no credential values or raw secret content.
- The denial result identifies the reason without leaking sensitive data.

## Proof Artifacts

- Effect identity and parameter-normalization schema.
- Approval binding examples.
- Mismatch and replay denial results.
- Profile, root, network, and process-owner invalidation results.
- Redaction audit.

## Milestone Traceability

This epic covers the Milestone 1 requirement to bind approval to the exact effect identity and normalized parameters.
