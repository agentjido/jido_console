---
epic: M2-E39
type: epic
title: Restore Paint-First Packaged TUI Startup
status: proposed
milestone: milestone-2
beadwork_id: jido_console-xou
depends_on: [M2-E38]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.3.3
last_updated_in: 1.3.3
---

# M2-E39: Restore Paint-First Packaged TUI Startup

## Goal

Make the packaged TUI paint before slow application startup. Attach the
session client only after the application supervisors are ready.

## Scope

- Remove eager application startup from the interactive CLI entry path.
- Build the initial TUI model list from trusted policy identity and tier data.
- Do not resolve the full LLMDB model catalog before the first frame.
- Paint the starting frame before application startup and session attach.
- Start application supervision before session attach and process
  registration in the packaged path.
- Queue terminal input that arrives while application or runtime startup is in
  progress.
- Show application, attach, registration, and runtime startup failures in the
  terminal.
- Do not let cleanup hide the original startup failure.

## Out of Scope

- A model policy or model support change
- A session protocol or client behavior change
- A release performance limit change
- Candidate qualification, audit, or publication

## Dependencies

This epic depends on M2-E38 because the repaired clean acceptance environment
exposed the packaged TUI defects. It blocks M2-E36 because the final candidate
must pass the unchanged first-frame, readiness, and TUI behavior checks.

## Pull Request Boundary

Deliver this epic in exactly one product repair pull request. It changes the
interactive startup order, its tests, the roadmap graph, and repair proof. It
does not qualify or publish a candidate.

## Acceptance Checks

- The first frame is drawn before application startup is called.
- TUI selection does not call the model metadata resolver before first paint.
- Application supervisors are ready before session attach and process
  registration.
- Input during startup is queued once and runs once after readiness.
- A startup failure stays visible until the operator exits.
- Cleanup cannot replace the original registration or startup error.
- Warm installed-package first paint is below 500 ms.
- Warm installed-package runtime readiness is below 1,250 ms.
- The successful and failed packaged TUI probes pass.
- Focused tests and the common precommit gate pass.

## Proof Artifacts

- `roadmap/milestones/02-ship-supervised-session-plane/proof/paint-first-packaged-tui.md`
- TUI and model-selection regression results
- Installed-package startup samples
- Installed-package success and failure probe results

## Milestone Traceability

This epic restores the unchanged release gate for the final supervised-session
candidate. It does not change the Milestone 2 product claim.
