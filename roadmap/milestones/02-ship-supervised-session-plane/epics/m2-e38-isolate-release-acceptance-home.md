---
epic: M2-E38
type: epic
title: Isolate the Release Acceptance Home
status: proposed
milestone: milestone-2
beadwork_id: jido_console-zs5
depends_on: [M2-E32]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.3.2
last_updated_in: 1.3.2
---

# M2-E38: Isolate the Release Acceptance Home

## Goal

Make the installed-artifact acceptance workflow use one explicit, private
`JIDO_HOME` in its clean environment.

## Scope

- Create one acceptance-only product home below the temporary acceptance root.
- Give the same home to startup measurements, packaged commands, TUI probes,
  the read-only package check, and the external coding workflow.
- Keep `HOME` and the operator home out of the installed-artifact environment.
- Remove the temporary product home with the other acceptance files.
- Record why the first M2-E36 candidate run stopped.

## Out of Scope

- A change to the product home contract
- A durable session home
- A new release channel or support claim
- Candidate qualification or a release decision

## Dependencies

This epic depends on M2-E32 because it repairs the final post-closeout release
gate. It blocks M2-E36 because qualification cannot start until the installed
artifact can start in its declared clean environment.

## Pull Request Boundary

Deliver this epic in exactly one repair pull request. The pull request changes
the acceptance harness, its tests, and its evidence. It does not qualify or
publish a candidate.

## Acceptance Checks

- The acceptance home is below the temporary acceptance root and has mode
  `0700`.
- Every installed-artifact path that starts the application receives the same
  explicit `JIDO_HOME`.
- The installed artifact starts with `HOME` absent.
- A normal installed TUI reaches idle with `HOME` absent and the explicit
  acceptance home present.
- The official gate advances beyond the missing-home failure. A different
  product failure must move to its own epic before M2-E36.
- The focused release-tooling tests and the common precommit gate pass.

## Proof Artifacts

- `roadmap/milestones/02-ship-supervised-session-plane/proof/release-acceptance-home.md`
- Focused release-tooling test result
- Installed-artifact startup result with `HOME` absent

## Milestone Traceability

This epic repairs the installed-artifact gate that M2-E36 must use. It does
not change the Milestone 2 session-plane claim.
