---
epic: M2-E21
type: epic
title: Build the Command and Client Registry
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e21
depends_on: [M2-E04]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E21: Build the Command and Client Registry

## Goal

Define commands and client capabilities once so every current surface uses the
same declaration.

## Scope

- Add one registry for command names, help, schemas, permissions, and
  provenance.
- Add client capability descriptors to the same registry contract.
- Define the command identity, version, input schema, output schema, and
  required permission data.
- Define the provenance record for a command declaration and client
  descriptor.
- Reject duplicate, incomplete, or conflicting declarations.
- Preserve bounded unknown declaration data without granting authority.
- Make registry lookup independent of renderer-specific data.

## Out of Scope

- Typed command-effect execution owned by M2-E22.
- Permission request and response transitions owned by M2-E24.
- Loading extensions or hosting extension processes.
- Migration of TUI, automation, text, or JSON adapters.

## Dependencies

This epic depends on M2-E04 for generated command and client protocol types
and validators.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request adds the
registry schema, declaration validators, lookup behavior, provenance data, and
deterministic registry tests. It must not implement client migration or
command-effect execution.

## Acceptance Checks

- Each command and client descriptor has one stable identity and version.
- Help, input schema, output schema, permission requirements, provenance, and
  client capabilities come from one declaration.
- Duplicate or conflicting declarations fail before registration completes.
- An incomplete declaration fails with a typed validation result.
- Unknown bounded fields remain data and cannot grant permission or authority.
- Registry lookups return renderer-neutral values.
- Deterministic tests cover registration, lookup, duplicate, invalid, and
  unknown-field cases.

## Proof Artifacts

- Command and client descriptor schema
- Registry declaration examples
- Provenance and version records
- Duplicate and invalid declaration results
- Registry validator test results

## Milestone Traceability

This epic covers the Milestone 2 requirement to put commands, help, schemas,
permissions, provenance, and client descriptors in one registry. It is the
declaration source for the typed effect, permission, extension, and client
contract epics.
