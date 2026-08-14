---
epic: M1-E16
type: epic
title: Enforce Network Boundaries
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e16
depends_on: [M1-E13]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E16: Enforce Network Boundaries

## Goal

Deny network access that the restricted profile does not declare.

## Scope

- Deny undeclared loopback access.
- Deny undeclared external network access.
- Define the network allowlist and its effective evidence record.
- Keep offline mode from making model or tool network calls.
- Use controlled local endpoints and test doubles for boundary tests.
- Return a clear policy denial before an undeclared connection can proceed.

## Out of Scope

- Provider support contracts.
- Remote executor adapters.
- Public network calls in tests.
- Child-process tree ownership.

## Dependencies

This epic depends on M1-E13 for the restricted execution profile and policy request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds network policy enforcement, offline denial, and controlled loopback and external-network tests.

## Acceptance Checks

- An undeclared loopback connection is denied.
- An undeclared external connection is denied without contacting a public service.
- A declared connection follows the versioned network policy.
- Offline mode blocks all model-network calls and undeclared tool-network calls.
- A network denial occurs before the request reaches the endpoint.
- Network evidence contains no credentials, private host data, or paid provider result.
- The Gate 0 hostile runtime-boundary network fixtures pass.

## Proof Artifacts

- Versioned network policy and effective allowlist.
- Loopback denial result.
- External-network denial result.
- Offline-mode result.
- Gate 0 hostile runtime-boundary network report.

## Milestone Traceability

This epic covers the Milestone 1 requirement to deny undeclared loopback and external network access in restricted execution.
