---
phase: gate-0
type: readiness_gate
title: Establish release readiness
status: proposed
depends_on: []
release: none
introduced_in: 0.1.0
last_updated_in: 1.0.1
---

# Gate 0: Establish Release Readiness

## Goal

Create a repeatable evidence base and an owned delivery graph before release work starts.

## Outcome

The team can compare each change with a known Jido CLI baseline. It also knows the critical path, package boundaries, owners, and proof artifacts for Phase 1.

Gate 0 is not a roadmap milestone and does not make a product release. Every numbered phase after this gate is a release milestone.

## Epic Breakdown

| Epic | Result |
| --- | --- |
| `G0-E1` Baseline evidence | Two repeatable clean builds, tests, release checks, and provider-free replay |
| `G0-E2` Golden and hostile fixtures | One fixed coding task plus security, terminal, and process-cleanup fixtures |
| `G0-E3` Dependency readiness | Approved Jidoka work, compatibility rules, and the Tilde reuse boundary |
| `G0-E4` Delivery graph | Linked milestone, owned Beadwork work, dependencies, critical path, and proof artifacts |

## Work

- Record the current test, production build, release, command, automation, artifact, and exit-status results.
- Run a clean cold build and the complete baseline suite two times with isolated build paths and Git configuration.
- Record redacted terminal, JSONL, Jidoka event, model-result, tool-result, and provider-free replay fixtures.
- Freeze the deterministic golden coding task that Phase 1 must run through the production artifact.
- Add layered TUI evidence for reducers, widths, terminal behavior, input, timing, and long sessions.
- Add hostile-workspace fixtures for secret access, undeclared file access, symbolic-link escape, network access, and child-process cleanup.
- Record package size, help startup, runtime readiness, first frame, and idle-memory measures.
- Define the first user, main job, activation measure, and initial support claim.
- Record separate Jidoka work, owners, release targets, proof, and merge order for event order, controller cleanup, policy defaults, unsafe-effect recovery, and execution-adapter contracts.
- Define the Jidoka compatibility and release requirements. Assign the dependency replacement to Phase 1.
- Record the Tilde source grant, attribution rules, and approved reuse boundary. Keep Tilde out of the runtime.
- Pin release-workflow dependencies, limit inherited secrets, and prevent a production publish when required tests are skipped.
- Create and link the Phase 1 GitHub milestone and one or more Beadwork epics.
- Give each Phase 1 Beadwork task an owner, effort class, dependency, readiness state, target release, and proof artifact.
- Identify the Phase 1 critical path and add an automated broken-traceability check.

## Out of Scope

- Product rename
- New session ownership
- Public feature release
- Implementation task detail in this roadmap file

## Exit Gate

- A clean checkout passes the complete baseline suite two times and produces the same semantic result.
- The production escript and OTP release build from clean state.
- `jido --version`, `jido --help`, the production PTY test, and required Jidoka parity tests pass.
- Recorded sessions replay without a paid model call and report prompt, call, tool, or event divergence.
- The hostile-workspace fixtures fail safely on the current known risks and are ready to prove the Phase 1 controls.
- The Jidoka compatibility plan and separate blocker work are approved and linked.
- The Tilde source grant and reuse boundary are recorded.
- The Phase 1 milestone, Beadwork epics, owned tasks, critical path, and proof artifacts are linked.
- The traceability check passes.

## Release Effect

Gate 0 does not make a release. It authorizes Phase 1 work after the exit gate passes.

## References

- [Contribution process](../../CONTRIBUTING.md)
- [Foundation and core backlog](../backlog/foundation-and-core.md)
