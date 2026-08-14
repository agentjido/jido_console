---
milestone: 7
type: release_milestone
title: Add managed and remote executors
status: proposed
depends_on: [milestone-6]
release: v0.7
introduced_in: 1.0.0
last_updated_in: 1.0.2
---

# Milestone 7: Add Managed and Remote Executors

## Goal

Run trusted BEAM workloads and explicit remote workloads without changing session semantics.

## Outcome

A session can use managed trusted OTP nodes and remote-host executors through versioned handshakes, explicit file custody, bounded credential delegation, monitoring, revocation, and audit.

## Work

- Add version, capability, trust-zone, file-custody, transfer, and protocol compatibility handshakes.
- Add a managed OTP-node executor with an independent dependency environment and failure domain.
- Start each managed node through a supervised system process and attach one monitored owner lease.
- Stop and clean the complete node when its owner or manager stops.
- State that an Erlang distribution peer is trusted and is not a security sandbox.
- Add remote-host adapters with explicit path, artifact-transfer, network, resource, and custody contracts.
- Use one-time bootstrap, short-lived executor grants, independent revocation, and sanitized audit events.
- Delegate only the declared environment and credential references for the declared operation.
- Prefer short-lived provider credentials when a provider supports them.
- Measure prompt-cache, transfer, latency, recovery, and cleanup effects before a remote adapter becomes a default.

## Out of Scope

- Untrusted execution on a distributed BEAM node
- Remote browser or SSH client access
- Multi-user collaboration
- Implicit shared file systems

## Exit Gate

- An incompatible managed or remote runtime cannot attach and receives a clear reason.
- Remote work does not assume access to local paths or credentials.
- A managed-node or remote-worker failure does not stop or corrupt the Console session.
- Startup timeout, node crash, owner crash, cancel, revocation, and normal stop leave no child process, grant, or temporary state.
- Two managed nodes can use different dependency environments without a session-code change.
- Security tests do not present node separation as protection from untrusted code.
- Credential delegation, use, expiry, and revocation are audited without a secret value.
- The remote support matrix matches measured protocol, transfer, cache, and recovery behavior.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.7 with managed trusted-node and remote executor support.
