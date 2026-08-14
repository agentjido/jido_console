---
phase: 10
title: Add controlled live extension
status: proposed
depends_on: [9]
release: v0.10
introduced_in: 0.1.0
last_updated_in: 1.0.1
---

# Phase 10: Add Controlled Live Extension

## Goal

Use BEAM code replacement without creating a security or recovery bypass.

## Outcome

Trusted extensions can update with exact-content review, health checks, state migration, rollback, durable evidence, and recovery code that stays outside the mutable runtime.

## Epic Breakdown

| Epic | Result |
| --- | --- |
| `P10-E1` Extension contracts | Trusted manifests, host contracts, capabilities, and hook failure policy |
| `P10-E2` Isolated artifact evaluation | Bound build, scan, test, schema, and artifact evidence |
| `P10-E3` Consent and trust promotion | Exact content approval and explicit promotion from restricted to trusted use |
| `P10-E4` Live migration and recovery | Reconstructible update, lease handoff, health check, rollback, and independent recovery |

## Work

- Define trusted extension manifests, stable host contracts, capability declarations, and a failure rule for each hook.
- Keep external-language tools behind the restricted executor protocol.
- Build, scan, test, and identify extension artifacts in isolation.
- Bind consent to exact paths, content, capabilities, schemas, and artifact digest.
- Store build, test, review, replay, selection, migration, health, and rollback evidence.
- Make each selected live mutation reconstructible from durable source and evidence.
- Run the launcher and recovery path outside the mutable active extension.
- Authenticate and lease process handoff before the old owner stops.
- Promote a restricted tool to a trusted extension only after explicit review of its bound evidence.
- Add one controlled update demonstration with session continuity, migration, health check, failed-update rollback, and audit.

## Out of Scope

- Direct load of unreviewed model output
- Use of hot code replacement as a sandbox
- A second agent runtime
- A large extension marketplace

## Exit Gate

- A reviewed extension updates without loss of session state.
- A failed update rolls back to the exact retained artifact.
- Any content, schema, path, or capability change requires a new approval.
- A clean process can reconstruct and verify the selected mutation.
- Recovery does not load damaged active code.
- The old owner stops only after an authenticated new owner holds the valid lease.
- A failed authority hook cannot permit an effect.
- Unreviewed model output cannot load into the trusted node.
- The complete load, health, migration, handoff, and rollback flow is in the audit record.
- The common milestone release gate in [the roadmap index](../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.10 with controlled live extension and rollback.

## References

- [Extensions and live update backlog](../backlog/extensions-and-live-update.md)
