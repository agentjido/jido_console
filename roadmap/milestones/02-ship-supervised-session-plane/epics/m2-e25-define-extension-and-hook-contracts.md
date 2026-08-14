---
epic: M2-E25
type: epic
title: Define Extension and Hook Contracts
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e25
depends_on: [M2-E04, M2-E21, M2-E24]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E25: Define Extension and Hook Contracts

## Goal

Define a small host-independent extension descriptor and one safe failure rule
for every hook type without loading extensions.

## Scope

- Define the host-independent extension descriptor and its version.
- Declare extension identity, capabilities, hook types, input schema, output
  schema, provenance, and trust data.
- Define the authority boundary for each hook type.
- Fail closed when an authority hook is missing, invalid, denied, or fails.
- Make information-only hook failures visible without granting authority.
- Preserve bounded unknown descriptor and hook data without granting authority.
- Validate descriptors through the command and client registry and permission
  contract.
- Do not connect the new descriptor to an extension loader or process host.

## Out of Scope

- Loading, resolving, or executing extensions.
- Extension process hosting or remote extensions.
- New authority policy beyond the declared hook rules.
- Client adapter migration.
- Changes to existing extension loading or hosting behavior.

## Dependencies

This epic depends on M2-E04 for generated semantic protocol types, M2-E21 for
command and client declarations, and M2-E24 for permission life-cycle data.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
descriptor schema, hook capability declarations, failure rules, validators,
and deterministic descriptor tests. It must not load or host an extension.

## Acceptance Checks

- A descriptor has one stable identity, version, capability set, hook set,
  schemas, provenance, and trust data.
- Every hook type has a declared authority or information-only failure rule.
- An authority hook failure returns a denied or failed result and grants no
  authority.
- An information-only hook failure is visible in the semantic result.
- Unknown bounded descriptor and hook data cannot grant authority.
- Invalid, conflicting, or incomplete descriptors fail validation.
- No code path introduced by this epic loads an extension or starts an extension process.
- Deterministic tests cover valid descriptors, invalid descriptors, authority
  failures, information-only failures, and unknown fields.

## Proof Artifacts

- Host-independent extension descriptor schema
- Hook capability and authority table
- Authority-failure and information-only-failure results
- Descriptor validation results
- Evidence that the new descriptor is not connected to loading or hosting

## Milestone Traceability

This epic covers the Milestone 2 requirement to define a small host-independent
extension descriptor and one failure rule for each hook type while keeping
extension loading out of scope.
