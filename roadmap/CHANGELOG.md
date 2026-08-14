# Roadmap Changelog

All important roadmap changes are in this file.

The roadmap uses [Semantic Versioning](https://semver.org/).

## [1.0.4] - 2026-08-14

### Added

- Add a Mermaid diagram that shows the dependency of each Gate 0 epic.
- Show the direct dependency from every prior Gate 0 epic to the final
  exit-gate audit.

## [1.0.3] - 2026-08-14

### Added

- Add 15 generated epics for Gate 0 under its milestone directory.
- Give each Gate 0 epic one pull request boundary, acceptance checks, proof
  artifacts, dependencies, and milestone traceability.
- Add a final evidence-audit epic that closes Gate 0 after all other Gate 0
  work merges.

### Changed

- Link the Gate 0 milestone to its generated epic index.
- Split the former four broad Gate 0 groups into reviewable one-pull-request
  delivery units without a change to the milestone outcome or exit gate.
- Define one pull request as the delivery unit for each generated epic and keep
  task dependencies and delivery status in Beadwork.

## [1.0.2] - 2026-08-14

### Changed

- Put each roadmap milestone in `roadmap/milestones/<name>/milestone.md`.
- Reserve an `epics/` directory under each milestone for epics generated from that milestone.
- Remove the incorrect nested epic table from each milestone file.
- Remove the copied `roadmap/backlog/` capability backlog.
- Keep generated epics and implementation delivery state in the milestone directory and Beadwork.
- Align the root roadmap, README, and ownership guidance with the milestone structure.

## [1.0.1] - 2026-08-14

### Changed

- Move the canonical roadmap and backlog into the main `jido_console` repository.
- Put milestone breakdowns in the dedicated `roadmap/epics/` folder.
- Group each milestone into a small set of named epics without changing its release outcome or exit gate.
- Keep `roadmap/README.md` and `roadmap/CHANGELOG.md` as the roadmap control files.

## [1.0.0] - 2026-08-14

### Added

- Add a non-release Gate 0 for repeatable evidence, cross-package readiness, source rights, and the owned Phase 1 delivery graph.
- Add a v0.4 supervised multi-agent release with durable child identity, budget and cancellation trees, named lanes, file custody, and monitored worktrees.
- Add separate releases for the local LiveView workbench, isolated local executors, managed and remote executors, authenticated remote web and SSH access, multi-user collaboration, and controlled live extension.
- Add one shared Console-to-Jidoka durable watermark and crash-reconciliation gate.
- Add the complete multi-model discovery, selection, capability, fallback, and durable-identity contract.
- Add a required production-artifact golden coding task and hostile-workspace safety evidence.
- Add an explicit platform-by-channel release matrix.
- Add a common working-release gate for every numbered milestone.

### Changed

- Make a safe, local, multi-model coding harness the primary first product.
- Make restricted execution the default v0.1 coding mode and move its minimum security boundary before collaboration.
- Combine the former semantic-core, session-owner, and current-client conversion phases into one v0.2 release train.
- Use process-lifetime input identity in v0.2 and reserve restart-safe admission for v0.3.
- Move supervised multi-agent work and worktree custody before the local web, remote, and multi-user releases.
- Split loopback-only single-user LiveView, authenticated remote access, and multi-user collaboration into different releases.
- Make controlled live extension an explicit v0.10 release.
- Require each milestone to demonstrate and ship a working installable release. Internal build stages now stay in Beadwork.
- Expand the capability backlog from 64 to 84 stable items and remap all retained items to the new release structure.
- Process SOL Ultra Review items 099 through 108 as direct roadmap inputs.

### Removed

- Remove internal-only roadmap milestones that did not produce working releases.
- Remove the multi-user-first product emphasis and the plan to ship collaboration before complete isolation and custody controls.

## [0.7.0] - 2026-08-14

### Added

- Add `@agentjido/jido-console` as the supported npm entry package.
- Add exact-version native target packages selected by operating system and CPU.
- Require the npm entry package and macOS ARM64 target for v0.1.
- Add global, local, `npm exec`, and `npx` installation checks.

### Changed

- Make Homebrew, npm, and direct archives use the same native release payload and gates.
- Prevent npm installation from compiling Erlang or Elixir or downloading a release through an install script.
- Keep later npm targets outside the support claim until their native releases pass the common gates.
- Expand the implementation backlog from 63 to 64 items.

## [0.6.0] - 2026-08-14

### Added

- Add OpenAI, Anthropic, and Google Gemini as the tested v0.1 providers.
- Add Ollama as beta after its provider contract passes.
- Add a stable Jido Console environment contract and safe credential diagnostics.
- Add provider-native credential chains and explicit environment-file loading to Phase 1.
- Add operating-system secret-store profiles to Phase 5.
- Add explicit credential and environment delegation to Phase 7.

### Changed

- Make provider support depend on declared contract evidence instead of ReqLLM availability.
- Remove a permanent hard-coded model name from the product contract.
- Prevent credentials from entering command arguments, Jido files, durable records, logs, events, traces, artifacts, or executor protocol records.
- Expand the implementation backlog from 59 to 63 items.

## [0.5.0] - 2026-08-14

### Added

- Add `~/.jido` as the default logical Jido home and `JIDO_HOME` as its override.
- Add a stable layout for configuration, durable state, logs, artifacts, cache, and process-local files.
- Add permission, legacy migration, backup, repair, retention, and removal requirements.
- Add a Phase 5 default local session store under the Jido home `state/` directory.

### Changed

- Make the local path resolver and safe diagnostic logs part of the Phase 1 release gate.
- Keep the local storage engine behind the Phase 5 storage adapter.
- Expand the implementation backlog from 57 to 59 items.

## [0.4.0] - 2026-08-14

### Added

- Add server-ordered shared-resource operations and client revision tracking to Phase 3.
- Add snapshot, operation, acknowledgement, presence, gap, and reconnect contracts to Phase 4.
- Add convergent shared documents and transient multi-user presence to Phase 6.
- Add a managed OTP-node executor with owner monitoring and complete cleanup to Phase 7.

### Changed

- Make real-time multi-user collaboration part of the Phase 6 outcome and release gate.
- Keep private drafts outside collaboration state.
- Define a managed OTP node as a trusted dependency and failure boundary, not as a sandbox.
- Expand the implementation backlog from 52 to 57 items.

## [0.3.0] - 2026-08-14

### Added

- Add a 52-item implementation backlog from the code-reference review.
- Add typed command effects, one command registry, event policy, and structured tool results to Phase 2.
- Add integrity identities, queue semantics, stream backpressure, exact drain, and two-stage cancellation to Phase 3.
- Add generated protocol types, client descriptors, parity checks, and unknown-message policy to Phase 4.
- Add atomic acceptance, reserved effect results, immutable history, exact recovery names, and bound approvals to Phase 5.
- Add session lanes, live thread controls, client-surface capabilities, and scoped client access to Phase 6.
- Add runtime handshakes, inherited restrictions, supervised resource ownership, and runtime support matrices to Phase 7.
- Add content-bound consent, reconstructible live changes, independent recovery, and authenticated handoff to Phase 8.

### Changed

- Expand the baseline gate with recorded-session replay and layered TUI tests.
- Make the runtime session server the only owner of live session state.
- Make durable admission happen before advisory execution wake-up.
- Make canonical history immutable and prompt compaction a projection.
- Make runtime location an adapter concern.
- Make each changed phase link to its detailed backlog.

## [0.2.0] - 2026-08-14

### Added

- Add traceability for all 41 X response items.
- Add release evidence rules for installation, examples, recovery, and product claims.
- Add an explicit session ownership and failure matrix.
- Add exact and transcript-only recovery levels.
- Add trust-zone, operator-access, and extension evidence requirements.

### Changed

- Make installation without an Elixir toolchain part of the v0.1 gate.
- Make public Jidoka projection contracts part of the semantic-core gate.
- Make client coordination use shared session events.
- Make prompt-cache measurement part of the remote executor decision.
- Make the controlled live-extension gate require a complete review evidence bundle.

## [0.1.0] - 2026-08-14

### Added

- Define Jido Console as the target product.
- Define nine ordered integration phases.
- Put each phase in a separate Markdown file.
- Define release gates from the current baseline through controlled live extension.
- Add roadmap version and change-control rules.
