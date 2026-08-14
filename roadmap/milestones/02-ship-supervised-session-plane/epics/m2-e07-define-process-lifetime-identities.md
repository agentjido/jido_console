---
epic: M2-E07
type: epic
title: Define Process-Lifetime Identities
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e07
depends_on: [M2-E04]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E07: Define Process-Lifetime Identities

## Goal

Bind every live session operation to the exact process-lifetime identity that owns it.

## Scope

- Define session identity.
- Define action identity.
- Define turn identity.
- Define lane identity.
- Define step identity.
- Define request identity.
- Define approval identity.
- Define control identity.
- Define client identity.
- Define model-invocation identity across provider, model, variant, generation settings, execution profile, prompt, tool schema, skill schema, and fallback attempt.
- Keep credential values out of every identity.
- Bind identity to the owning process lifetime and session.
- Reject stale, repeated, and cross-session results before they resolve current work.

## Out of Scope

- Durable identities after application restart.
- Session-server implementation.
- Client delivery and acknowledgement.
- Multi-agent child-session identity.

## Dependencies

This epic depends on M2-E04 for generated protocol types and validators.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request defines identity types, ownership bindings, result admission checks, and deterministic stale-result tests. It must not add restart-safe receipts.

## Acceptance Checks

- Each listed identity type has a stable format and owner.
- A result is accepted only when its identity matches the live process and session.
- A stale result cannot resolve current work.
- A repeated result cannot create a second outcome or event.
- A cross-session result is rejected.
- Identity checks do not infer authority from host, origin, or transport.
- Identity data is bounded and safe for the protocol.
- Model invocation identity names the complete effective invocation without a credential value.

## Proof Artifacts

- Process-lifetime identity schema.
- Identity ownership matrix.
- Stale-result rejection results.
- Repeated-result rejection results.
- Cross-session rejection results.

## Milestone Traceability

This epic covers the Milestone 2 requirement to bind actions, turns, lanes, requests, approvals, controls, clients, and model invocations to exact process-lifetime identities.
