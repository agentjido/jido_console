---
milestone: 6
type: release_milestone
title: Add isolated local executors
status: proposed
depends_on: [milestone-5]
release: v0.6
introduced_in: 1.0.0
last_updated_in: 1.0.2
---

# Milestone 6: Add Isolated Local Executors

## Goal

Generalize the v0.1 restricted path into a location-neutral local executor protocol.

## Outcome

The session can run tools through supported local process, port, isolated-service, and container adapters with explicit custody, resource, network, environment, cancellation, and cleanup behavior.

## Work

- Define versioned language-neutral executor request, result, cancellation, stream, and artifact-transfer messages.
- Make runtime location an adapter concern. Keep session behavior independent from adapter location.
- Give each subprocess protocol one supervised owner for frame buffering, parsing, identity, controls, standard error, and exit.
- Add local process, port, isolated-service, and container adapters only after each support tier passes.
- Define explicit file roots, mounts, artifacts, network policy, environment, credentials, resources, deadlines, and process-tree custody.
- Require child policy to narrow inherited authority.
- Publish one executor support matrix with owner, trust zone, isolation claim, and unsupported behavior.
- Preserve bounded unknown protocol data without granting it authority.
- Produce build, scan, test, and artifact evidence for generated tools inside a restricted executor.

## Out of Scope

- Remote-host execution
- Managed trusted BEAM nodes
- Remote client access
- Promotion of generated code into the trusted Console node

## Exit Gate

- Executor failure does not stop or corrupt the session.
- Session behavior and protocol data do not depend on executor location.
- Each claimed adapter passes its published file, mount, network, environment, credential, resource, cancellation, and custody checks.
- An untrusted workload cannot join the trusted BEAM distribution group.
- Cancel, timeout, owner exit, adapter crash, and normal completion leave no child process or temporary state.
- A delegated request cannot gain authority or capacity.
- A generated artifact cannot gain trust from a compile result alone.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.6 with supported isolated local executor adapters.
