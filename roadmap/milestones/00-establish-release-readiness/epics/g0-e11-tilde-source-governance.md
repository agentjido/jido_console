---
epic: G0-E11
type: epic
title: Record Tilde source governance
status: proposed
milestone: gate-0
depends_on: []
release: none
delivery_unit: one_pull_request
introduced_in: 1.0.3
last_updated_in: 1.0.3
---

# G0-E11: Record Tilde Source Governance

## Goal

Record the approved Tilde source grant, attribution rules, and reuse boundary.

## Scope

- Link or record the approved source grant in a safe form.
- State the required attribution text and location.
- List approved architecture and renderer pattern areas.
- List prohibited reuse areas from the roadmap.
- Define the review owner and the check for a proposed reuse.
- Prove that Tilde is not a runtime dependency.

## Out of Scope

- Tilde code reuse
- A Tilde runtime dependency
- A new source grant
- Confidential legal text in the repository

## Dependencies

This epic has no Gate 0 dependency. The source grant must exist before the pull request can merge.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request records the approved boundary and proof. It must not copy or adapt Tilde source.

## Acceptance Checks

- A reviewer can determine if a proposed reuse is permitted.
- The record identifies the grant authority and approval date without confidential content.
- Attribution requirements have one named location.
- Approved and prohibited reuse areas agree with the roadmap.
- Dependency checks show no Tilde runtime dependency.

## Proof Artifacts

- Source-grant reference
- Attribution decision
- Approved and prohibited reuse matrix
- Runtime dependency check

## Milestone Traceability

This epic covers the Tilde source grant, attribution rules, approved reuse boundary, and runtime exclusion in Gate 0.
