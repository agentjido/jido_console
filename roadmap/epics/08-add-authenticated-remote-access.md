---
phase: 8
title: Add authenticated remote access
status: proposed
depends_on: [7]
release: v0.8
introduced_in: 1.0.0
last_updated_in: 1.0.1
---

# Phase 8: Add Authenticated Remote Access

## Goal

Give one operator secure remote browser and SSH access without adding multi-user shared-state rules.

## Outcome

An authenticated operator can attach to an authorized session through a remote web or SSH client with short-lived grants, revocation, audit, safe input handling, and the same semantic controls as local clients.

## Epic Breakdown

| Epic | Result |
| --- | --- |
| `P8-E1` Remote identity and grants | Principals, roles, scoped grants, tickets, expiry, authorization, and revocation |
| `P8-E2` Remote web access | Explicit binding, TLS, origin, host, proxy, and deployment policy |
| `P8-E3` SSH client | Supported terminal transport with correct input, cancel, resize, and scrollback behavior |
| `P8-E4` Network limits and audit | Connection, stream, idle, and resource limits with sanitized evidence |

## Work

- Define client principal, role, session grant, client identity, transport identity, expiry, and revocation data.
- Exchange one-time bootstrap access for a scoped session grant and short-lived connection ticket.
- Add explicit remote binding, TLS, origin, host, proxy, and deployment policy for the web client.
- Add a supported SSH transport as a `Session.Client`.
- Buffer split terminal input sequences and keep per-client draft state local.
- Make Ctrl+C request session cancellation when work is active and close only through an explicit client action.
- Repaint on terminal resize and keep terminal output compatible with normal scrollback.
- Apply authorization before attach, command, approval, cancellation, or session control.
- Add rate, connection, stream, idle, and resource limits.
- Record sanitized attach, deny, control, revoke, and disconnect audit events.

## Out of Scope

- More than one authorized user in a session
- Organization identity and membership
- Shared document editing
- Multi-user presence

## Exit Gate

- A bootstrap credential cannot act as a normal session credential.
- Each client grant expires and can be revoked without revoking another grant.
- An unauthenticated or unauthorized client cannot list, attach to, inspect, or control a session.
- Remote web and SSH clients pass the shared contract suite for declared capabilities.
- SSH cancellation, split escape sequences, ordinary `q` and `r` text, resize, and scrollback behavior pass terminal tests.
- A slow or disconnected remote client cannot cause unbounded memory or session failure.
- Network exposure, grant use, denial, control, and revocation produce sanitized audit evidence.
- The common milestone release gate in [the roadmap index](../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.8 with authenticated single-operator remote web and SSH access.

## References

- [Clients and protocol backlog](../backlog/clients-and-protocol.md)
