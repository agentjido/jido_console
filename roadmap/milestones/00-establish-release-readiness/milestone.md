---
milestone: gate-0
type: readiness_gate
title: Establish release readiness
status: proposed
depends_on: []
release: none
introduced_in: 0.1.0
last_updated_in: 1.0.3
---

# Milestone Gate 0: Establish Release Readiness

## Goal

Create a repeatable local release audit and an owned delivery graph before release work starts.

## Outcome

The team can audit a selected clean Jido Console source without adding cost to normal development. It also knows the critical path, package boundaries, owners, and proof artifacts for Milestone 1.

Gate 0 does not make a product release. Every numbered milestone after this gate is a release milestone.

## Epics

The [epic index](epics/README.md) splits this milestone into 15 work items. The implementation branch keeps one commit for each work item.

## Work

- Record the current test, production build, release, command, automation, artifact, and exit-status results.
- Run a clean cold build and the complete baseline suite two times with isolated build paths and Git configuration.
- Record redacted terminal, JSONL, Jidoka event, model-result, tool-result, and provider-free replay fixtures.
- Freeze the deterministic golden coding task that Milestone 1 must run through the production artifact.
- Add layered TUI evidence for reducers, widths, terminal behavior, input, timing, and long sessions.
- Add hostile-workspace fixtures for secret access, undeclared file access, symbolic-link escape, network access, and child-process cleanup.
- Record package size, help startup, runtime readiness, first frame, and idle-memory measures.
- Define the first user, main job, activation measure, and initial support claim.
- Record separate Jidoka work, owners, release targets, proof, and merge order for event order, controller cleanup, policy defaults, unsafe-effect recovery, and execution-adapter contracts.
- Define the Jidoka compatibility and release requirements. Assign the dependency replacement to Milestone 1.
- Record the Tilde source grant, attribution rules, and approved reuse boundary. Keep Tilde out of the runtime.
- Pin release-workflow dependencies, limit inherited secrets, and prevent a production publish when required tests are skipped.
- Create and link the Milestone 1 GitHub milestone and one or more Beadwork epics.
- Give each Milestone 1 Beadwork task an owner, effort class, dependency, readiness state, target release, and proof artifact.
- Identify the Milestone 1 critical path and add an automated broken-traceability check.

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
- The hostile-workspace fixtures fail safely on the current known risks and are ready to prove the Milestone 1 controls.
- The Jidoka compatibility plan and separate blocker work are approved and linked.
- The Tilde source grant and reuse boundary are recorded.
- The Milestone 1 milestone, Beadwork epics, owned tasks, critical path, and proof artifacts are linked.
- The traceability check passes.

## Release Effect

Gate 0 does not make a release. `mix precommit` remains the normal development check. `mix jido.release.audit` is an explicit release-preparation task. Generated audit results stay local and are not source files. A future source-freeze review makes the release-readiness decision.
