---
epic: M2-E24
type: epic
title: Complete the Permission Life Cycle
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e24
depends_on: [M2-E07, M2-E13, M2-E21, M2-E22]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E24: Complete the Permission Life Cycle

## Goal

Define one exact permission request and response life cycle for every client
and controlled effect.

## Scope

- Use the permission-request and approval identity types from M2-E07 and define the requesting principal.
- Bind each request to its rule, control, effect, session, run, and request
  scope.
- Define decision scope, response values, expiry, cancellation, and audit
  records.
- Require an exact match between the permission response and the pending
  request.
- Reject stale, repeated, cross-session, cross-principal, and mismatched
  responses.
- Expose permission requests and responses as semantic data for the later
  `Session.Client` contract.
- Return a typed result for approved, denied, expired, cancelled, and invalid
  permission decisions.
- Do not use polling to complete the permission life cycle.

## Out of Scope

- The command and client declaration registry owned by M2-E21.
- Typed command-effect definitions owned by M2-E22.
- Client adapter migration.
- Durable permission recovery after an application restart.
- Automatic approval or a new authority policy.

## Dependencies

This epic depends on M2-E07 for request and approval identities, M2-E13 for the
session owner and control state, M2-E21 for permission declarations, and M2-E22 for
typed command effects.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request uses the
existing identities and adds permission request and response records, exact
matching, expiry and cancellation behavior, audit records, and deterministic
lifecycle tests. It must not redefine identity, migrate a client adapter, or
add polling.

## Acceptance Checks

- Every permission request has an identity, principal, rule, control, effect,
  decision scope, and exact session/run/request scope.
- Responses accept only the matching pending request.
- Stale, repeated, cross-session, cross-principal, and mismatched responses
  fail clearly without affecting current work.
- Expiry and cancellation produce typed outcomes and unblock the session safely.
- Permission audit records include the decision and scope without secret
  values.
- The life cycle completes through events or direct control responses and does
  not poll.
- Deterministic tests cover approve, deny, expire, cancel, stale, repeated,
  and mismatched responses.

## Proof Artifacts

- Permission request and response schema
- Identity and exact-match rules
- Decision-scope and expiry table
- Approve, deny, expire, cancel, and invalid result records
- No-polling lifecycle test results
- Redacted permission audit records

## Milestone Traceability

This epic covers the Milestone 2 requirement to define the complete permission
request and response life cycle with exact matching, expiry, cancellation, and
audit evidence.
