---
epic: M2-E32
type: epic
title: Remove the Old TUI-Owned Session Path
status: proposed
milestone: milestone-2
beadwork_id: jido_console-m2e32
depends_on: [M2-E31]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.0.7
last_updated_in: 1.0.7
---

# M2-E32: Remove the Old TUI-Owned Session Path

## Goal

Remove the former TUI-owned session and turn path after client parity passes.

## Scope

- Delete the old TUI session and turn ownership path.
- Remove tests, adapters, and documentation that support only the deleted path.
- Keep the migrated TUI on `Session.Client` as the only supported terminal path.
- Prove that no compatibility shim retains duplicate ownership.

## Out of Scope

- New TUI behavior.
- A compatibility shim for the deleted path.
- Session durability across application restart.
- Changes to other current clients except required reference updates.

## Dependencies

This epic depends on M2-E31 because current-client parity must pass before the old ownership path is removed.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request removes the old TUI-owned path and does not add a compatibility shim.

## Acceptance Checks

- No production path gives the TUI ownership of a Jidoka session, active run, queue, or event order.
- The TUI uses only `Session.Client` and the supervised session owner.
- The deleted path has no compatibility shim or fallback.
- TUI, automation, text, and JSON parity tests continue to pass.
- Source-boundary checks reject the removed ownership path.

## Proof Artifacts

- Removed-path inventory.
- Source-boundary check result.
- Current-client parity rerun.
- TUI session-owner evidence.

## Milestone Traceability

This epic covers the Milestone 2 removal of the old TUI-owned session and turn path.
