---
epic: M1-E07
type: epic
title: Build the Provider Contract Harness
status: proposed
milestone: milestone-1
beadwork_id: jido_console-m1e07
depends_on: [M1-E05, M1-E06]
release: v0.1
delivery_unit: one_pull_request
introduced_in: 1.0.6
last_updated_in: 1.0.6
---

# M1-E07: Build the Provider Contract Harness

## Goal

Build one deterministic harness that records provider contract results for each declared model capability.

## Scope

- Run recorded deterministic checks for normal provider behavior without a live provider call.
- Add bounded explicit live contract checks for streaming, tools, multi-turn tool use, structured results, cancellation, timeout, usage, cost, prompt cache, and error normalization.
- Bind each result to the exact provider, model, contract version, and test identity.
- Record pass, fail, blocked, and not-applicable results with the reason and evidence source.
- Redact credentials, private paths, prompt secrets, and provider response secrets from reports.
- Produce evidence that M1-E06 can reference for each capability and limit.
- Keep live checks opt-in, bounded, and separate from normal deterministic tests.

## Out of Scope

- Declaring a provider or model supported
- Credential storage or credential diagnostics
- Model selection or fallback policy
- Unbounded live provider calls
- Product release publication

## Dependencies

This epic depends on M1-E05 for the model and runtime contract boundary and M1-E06 for catalog identities and capability fields.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the provider contract harness, controlled fixtures, result schema, and focused tests. It must not add a provider support claim.

## Acceptance Checks

- Deterministic checks run without a live provider or paid call.
- Live checks have an explicit opt-in, timeout, cancellation path, and bounded data set.
- Each result identifies the exact provider, model, capability, contract version, and source mode.
- The harness covers every declared contract dimension or records a clear not-applicable reason.
- A failed or blocked check cannot be converted to a passing result by omission.
- Reports contain no credential value, private path, or unredacted sensitive response.

## Proof Artifacts

- Provider contract schema and harness command
- Recorded deterministic fixture set
- Bounded live-contract result format
- Capability result matrix
- Redaction and failure-classification results

## Milestone Traceability

This epic supplies the recorded and bounded provider evidence used by the Milestone 1 model catalog and provider qualification epics.
