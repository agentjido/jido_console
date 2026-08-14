---
phase: 9
title: Add multi-user collaboration
status: proposed
depends_on: [8]
release: v0.9
introduced_in: 1.0.0
last_updated_in: 1.0.1
---

# Phase 9: Add Multi-User Collaboration

## Goal

Add authorized shared work only after local durability, custody, isolation, and remote access are proven.

## Outcome

Several authorized users can observe and change declared shared resources with one server order, convergent text, transient presence, and explicit responsibility for each accepted effect.

## Epic Breakdown

| Epic | Result |
| --- | --- |
| `P9-E1` Organization identity and authorization | Users, memberships, roles, resources, and permission checks before admission |
| `P9-E2` Shared operation log | Revisions, acknowledgements, gaps, snapshots, reconnect, and deterministic no-change results |
| `P9-E3` Convergent editing | One versioned CRDT or operational-transformation contract for declared resources |
| `P9-E4` Presence and responsibility | Private drafts, transient presence, operator identity, audit, and custody under concurrency |

## Work

- Add user, organization, membership, role, session, resource, and client identities.
- Define list, attach, observe, submit, edit, approve, cancel, and administration permissions.
- Apply authorization before an operation enters the session order.
- Give each shared resource a server revision and track acknowledged client revisions.
- Define snapshot, operation, acknowledgement, revision, gap, reconnect, and deterministic no-change messages.
- Declare which plans, workbench documents, and review notes support shared editing.
- Select and version one operational-transformation or CRDT contract for concurrent text.
- Add transient active-user, focus, cursor, and selection presence.
- Keep command drafts and undeclared resources private to each client.
- Show origin, principal, role, trust, policy, and approval responsibility in views and audit records.
- Preserve executor and worktree custody for every collaborative operation.

## Out of Scope

- Shared unsubmitted command drafts
- Implicit edit access from transport or origin
- Public anonymous sessions
- Live code extension

## Exit Gate

- At least three authorized clients converge after concurrent inserts, deletes, and replacements arrive in different orders.
- A late or reconnected client reaches current state from a snapshot and ordered operations.
- A stale or invalid concurrent operation has one deterministic no-change result.
- A user without edit or approval authority cannot cause the protected operation to enter session order.
- Join, leave, focus, cursor, and selection state is responsive, permission-aware, and absent from durable semantic history.
- Private drafts never enter shared state.
- Identity, authorization, executor, and worktree controls remain effective under concurrent load and revocation.
- Every accepted unsafe effect identifies the responsible operator and exact approval scope.
- The common milestone release gate in [the roadmap index](../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.9 with supported multi-user collaboration.

## References

- [Session runtime backlog](../backlog/session-runtime.md)
- [Clients and protocol backlog](../backlog/clients-and-protocol.md)
- [Views and TUI backlog](../backlog/views-and-tui.md)
