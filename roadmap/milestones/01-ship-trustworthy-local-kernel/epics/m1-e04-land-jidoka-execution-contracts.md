---
epic: M1-E04
type: epic
title: Land the Jidoka Policy and Execution Contracts
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e04
depends_on: [G0-E15]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E04: Land the Jidoka Policy and Execution Contracts

## Goal

Add the Jidoka contracts that the restricted v0.1 path needs before Console integration.

## Scope

- Deliver one external Jidoka pull request with additive policy contracts.
- Deliver the execution-adapter contracts needed by the restricted local path.
- Define policy requests, decisions, capability data, enforcement evidence, cancellation, and cleanup results required by the v0.1 boundary.
- Define the compatibility contract for the additive release.
- Link the external pull request and its proof to the Milestone 1 delivery graph.

## Out of Scope

- Jido Console integration.
- A Jido Console dependency update.
- Private Jidoka runtime or adapter internals in Console.
- A mutable Jidoka branch or unversioned package.
- New provider, model, or packaging behavior.

## Dependencies

This epic depends on G0-E15 for the approved Jidoka blocker plan and Gate 0 exit decision.

## Pull Request Boundary

Deliver this epic through exactly one linked pull request in the Jidoka repository. The pull request must contain only the additive policy and execution-adapter contracts needed for the restricted v0.1 path. It must not contain Jido Console integration.

## Acceptance Checks

- The external pull request has one immutable source identity and one approved release target.
- The policy contract represents allow, deny, consent-required, and unsupported decisions.
- The execution-adapter contract represents explicit roots, environment, credentials, network, resources, cancellation, deadlines, and cleanup evidence.
- The contract preserves bounded unknown data without granting authority.
- The compatibility test passes for the required v0.1 contract.
- The external pull request, owner, proof, and merge position are linked from the Milestone 1 graph.

## Proof Artifacts

- External Jidoka pull request link.
- Immutable source and release identity.
- Policy and execution-adapter contract schema.
- Compatibility test result.
- Additive API review result.

## Milestone Traceability

This epic covers the Milestone 1 work to land the additive Jidoka policy and execution-adapter contracts before Console integration.
