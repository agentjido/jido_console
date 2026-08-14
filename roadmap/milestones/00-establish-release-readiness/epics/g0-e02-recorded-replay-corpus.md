---
epic: G0-E02
type: epic
title: Capture the recorded replay corpus
status: proposed
milestone: gate-0
beadwork_id: jido_console-g0e02
depends_on: [G0-E01]
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.5
---

# G0-E02: Capture the Recorded Replay Corpus

## Goal

Create a redacted record set that detects changes in a provider-free session replay.

## Scope

- Record terminal, JSONL, Jidoka event, model-result, and tool-result data.
- Use `priv/release/offline_fixture.json` as the only canonical provider-free replay source.
- Define stable redaction and normalization rules.
- Compare prompt, model-call, tool, and event records.
- Report the record type and location of each divergence.
- Keep controlled fixtures in their existing release and test fixture areas.

## Out of Scope

- A second offline fixture source
- Live model calls in tests
- Durable resume or Milestone 3 recovery behavior
- The golden coding task from G0-E03

## Dependencies

This epic depends on G0-E01 for the evidence schema and clean-run identity.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the record set, replay comparison, redaction rules, and focused tests.

## Acceptance Checks

- Replay completes without a paid model call.
- Each required record type has a redacted fixture.
- A controlled change to each record type produces a clear divergence result.
- Repeated replay of unchanged inputs produces the same semantic result.
- No fixture or report contains a credential value or canary secret.
- No fixture duplicates the canonical offline replay source.

## Proof Artifacts

- Versioned replay manifest
- Redacted terminal and structured records
- Divergence test results for each record type
- Provider-free replay result

## Milestone Traceability

This epic covers the recorded session fixtures and the provider-free divergence check in Gate 0.
