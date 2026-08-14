---
milestone: 1
type: release_milestone
title: Ship the trustworthy local kernel
status: proposed
depends_on: [gate-0]
release: v0.1
introduced_in: 0.1.0
last_updated_in: 1.0.6
---

# Milestone 1: Ship the Trustworthy Local Kernel

## Goal

Ship a safe, local, multi-model coding harness through the current terminal and automation surfaces.

## Outcome

A new user can install Jido Console, select a tested model and restricted execution profile, complete one coding task, review the exact effects, and leave or restore the workspace to a known state.

## Delivery control

- [GitHub milestone 1](https://github.com/agentjido/jido_console/milestone/1) is the public milestone record.
- Beadwork is the source of truth for task ownership, state, dependencies, and proof plans. Use `bw list --label milestone-1` for current state.
- [The delivery plan](delivery-plan.json) stores stable identifiers and the critical path. It does not copy current task state.
- [The first-user support boundary](../00-establish-release-readiness/first-user-support.md) defines the initial claim.
- The critical path ends at `jido_console-m1e30`, after the release audit in `jido_console-m1e29`.

## Generated Epics

The [Milestone 1 epic index](epics/README.md) splits this milestone into 30 epics. Each epic is the scope for exactly one pull request.

## Work

- Rename the repository and package to `jido_console`, the OTP application to `:jido_console`, and the namespace to `Jido.Console`.
- Keep `jido` as the command and preserve the current command, automation, JSONL, artifact, signal, and exit-status contracts.
- Make installation and first run work without an existing Elixir or Erlang toolchain.
- Define status and shutdown behavior for each local background process.
- Establish one Jido home with `JIDO_HOME`, stable subdirectories, safe permissions, migration, backup, update, and removal rules.
- Publish one signed native release payload with checksums, software bill of materials, and provenance.
- Support the v0.1 matrix: macOS ARM64 by direct archive, Homebrew, and npm.
- Publish `@agentjido/jido-console` and an exact-version macOS ARM64 target package. Do not compile Erlang or Elixir or download a release in an npm install script.
- Publish supported, beta, available, and unsupported model tiers.
- Support OpenAI, Anthropic, and Google Gemini after their declared contracts pass. Keep Ollama beta until its beta contract passes.
- Add `jido models list`, `jido models show`, and `jido models test`.
- Add `/model` and `/profile` selection to the TUI. Always show the effective model and settings before work starts.
- Publish model capability, limit, cost, cancellation, prompt-cache, and known-gap data for each support claim.
- Fail before a turn when the model lacks a required feature.
- Require consent before fallback changes provider, data boundary, cost class, or capability.
- Add `jido auth status`, `jido auth doctor`, and `jido doctor` without showing credential values.
- Resolve credentials through declared sources. Do not accept credentials in command arguments or put them in configuration, events, logs, traces, artifacts, or session data.
- Land the additive Jidoka policy and execution-adapter contracts that the restricted v0.1 path needs before Console integration.
- Use an approved versioned Jidoka release or package and pass its compatibility contract. Do not ship an integration that follows a mutable branch.
- Make restricted execution the default coding mode. Use an explicit environment allowlist and a private temporary `HOME`.
- Restrict file access to declared workspace, toolchain, artifact, and temporary roots. Reject symbolic-link escape.
- Deny undeclared loopback and external network access.
- Own and stop the complete child-process tree on normal completion, rejection, cancel, timeout, and owner exit.
- Bind approval to the exact effect identity and normalized parameters.
- Keep trusted-workspace mode as an explicit option only. Label it as not a sandbox and do not use it for the restricted-execution gate.
- Run the frozen golden task through the production artifact with recorded provider results when possible.
- Prove repository discovery, read, search, edit, command, test, exact diff, approval, rejection, cancellation, and current-run patch revert.

## Out of Scope

- Client-independent session ownership
- Restart-safe session recovery
- Multi-agent work
- LiveView, SSH, or multi-user operation
- General container or remote executor adapters
- Platform and channel pairs outside the declared v0.1 matrix

## Exit Gate

- All declared v0.1 platform and channel cells pass install, first run, update, and removal tests.
- A clean supported system installs and completes first run without an existing Elixir or Erlang toolchain.
- Homebrew, npm, and direct archive use the same native payload, version, license, checksums, and provenance.
- OpenAI, Anthropic, and Google Gemini pass every claimed provider and model contract.
- Offline mode blocks all network model calls.
- The model picker and commands show exact support, capability, profile, and effective-setting data.
- A fallback that changes a trust, cost, or capability boundary cannot occur without consent.
- The integrated Jidoka version passes the approved compatibility contract and does not follow a mutable branch.
- The production artifact completes the complete golden coding task in restricted mode.
- Rejection leaves the workspace unchanged, and current-run revert restores the recorded pre-run state.
- A repository process cannot read provider credentials, undeclared host files, or a canary secret.
- Symbolic-link, undeclared loopback, and undeclared external network tests fail safely.
- Normal completion, rejection, cancel, timeout, and owner exit leave no child process.
- Background-process status and shutdown use normal `jido` command behavior and leave no owned process after shutdown.
- The common milestone release gate in [the roadmap index](../../README.md#common-milestone-release-gate) passes.

## Release Effect

Ship Jido Console v0.1 as a trustworthy local multi-model coding kernel. Do not claim durable session recovery.
