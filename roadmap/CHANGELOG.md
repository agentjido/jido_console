# Roadmap Changelog

All important roadmap changes are in this file.

The roadmap uses [Semantic Versioning](https://semver.org/).

## [1.3.4] - 2026-08-17

### Added

- Add M2-E40 to preserve the native package root when npm exposes the Jido
  command.

### Changed

- Make M2-E40 depend on M2-E39 and block M2-E36 after the channel gate found
  that the copied npm launcher could not find its private runtime.
- Increase the Milestone 2 epic count from 39 to 40 and add the npm repair to
  the final closeout chain.

## [1.3.3] - 2026-08-17

### Added

- Add M2-E39 to restore paint-first startup for the packaged TUI after the
  repaired acceptance gate exposed eager startup and missing-supervisor
  failures.

### Changed

- Make M2-E39 depend on M2-E38 and block M2-E36.
- Increase the Milestone 2 epic count from 38 to 39 and add the TUI startup
  repair to the final closeout chain.

## [1.3.2] - 2026-08-17

### Added

- Add M2-E38 to give installed-artifact acceptance one explicit private
  `JIDO_HOME` in its clean environment.

### Changed

- Make M2-E38 block M2-E36 after the candidate gate proved that an environment
  without `HOME` could not start the application.
- Increase the Milestone 2 epic count from 37 to 38 and add the repair to the
  final closeout chain.

## [1.3.1] - 2026-08-16

### Added

- Create the `jido_console-m3` Beadwork parent and load all 37 Milestone 3
  one-pull-request epics below it with their final reserved identifiers.
- Add 37 parent-child relations and the exact 110 direct roadmap dependency
  relations, including the single M2-E37 to M3-E01 implementation gate.

### Changed

- Replace every Milestone 3 reserved import identifier with its verified
  `beadwork_id` and record the loaded hierarchy in the milestone and epic
  index.
- Set all 37 required v0.3 epics to P1. Apply `effort:medium` to M3-E01,
  M3-E05, M3-E09, M3-E23, M3-E25, M3-E27, and M3-E37, and apply
  `effort:large` to the other 30 epics.
- Load the records early for work tracking by explicit user direction. Keep
  M3-E01 blocked by M2-E37, and keep `jido_console-x5b` open for final-source
  comparison and graph verification before implementation starts.

## [1.3.0] - 2026-08-16

### Added

- Add 37 complete proposed Milestone 3 epic specifications with one pull
  request, acceptance boundary, proof set, and direct dependency list for each
  epic after import.
- Add a Milestone 3 planning baseline with the durable-record inventory,
  acknowledgement rules, generation fence, recovery topology, watermark state
  machine, operation matrix, crash matrix, hard growth limits, and candidate
  qualification profile.
- Add the read-only Milestone 2 Beadwork closeout review, exact nine-epic
  critical chain, only-ready item, and the remaining `jido_console-x5b`
  import responsibility.
- Add separate epics for SQLite qualification, durable Console schemas,
  upstream Jidoka hardening, the default store, bounded writer ownership,
  early quotas, event history, restart-safe receipts, queues, secret-free
  credential profiles, turn manifests, effects, watermarks, backup, migration,
  restore, physical repair, recovery, exact and transcript-only resume,
  semantic repair, retry, fork, history access, client attachment, archive,
  destructive removal, client workflows, proof, candidate qualification, and
  final audit.
- Reserve deterministic Beadwork import IDs from `jido_console-m3e01` through
  `jido_console-m3e37` while keeping every `beadwork_id` null. Do not load the
  records before the Milestone 2 audit.

### Changed

- Select SQLite as the default Milestone 3 indexed engine. M3-E02 selects and
  qualifies the direct Elixir adapter before storage implementation.
- Freeze the SQLite, DETS, DuckDB, and versioned-plain-file comparison in the
  planning baseline. M3-E02 verifies that record and supplies adapter evidence.
- Require all product-created durable database, sidecar, lock, backup, archive,
  quarantine, manifest, and temporary files to stay below `JIDO_HOME/state/`.
- Use one bounded SQLite database with separate logical Console and Jidoka
  truth tables, one supervised writer, a supervised stopped-store maintenance
  owner, a home lock, exact database-page and WAL reserves, and hard category
  and total-state limits.
- Keep credential values outside durable state. Add secret-free profiles that
  can read an existing environment, private dotenv, or operating-system
  keychain reference only at the final provider or tool boundary. Do not let
  Jido create or change an external secret value.
- Split quota, backup, migration, restore, physical repair, archive, and
  destructive removal into separate ownership and pull-request boundaries.
- Keep source backups in the backup budget, current authority in the active
  budget, and only one staged or prior image in the shared work pool. Use a
  crash-safe external manifest for restore and repair role changes.
- Start the supervised maintenance coordinator before any SQLite connection so
  it can reconcile the external operation manifest with one clear owner.
- Treat whole-store backups and quarantine images as indivisible copies. A
  session removal blocks until separate whole-image retirement removes every
  shared copy that contains the session.
- Give confirmed session removal and whole-image retirement a small closed
  control-capacity allowance. Require a stopped terminal or abandoned session,
  generation fence, client detach, and writer maintenance barrier for
  per-session removal.
- Split recovery classification from exact and transcript-only owner startup.
  Store migration runs once before the session catalog starts.
- State the credential guarantee as structural credential-field rejection,
  final-call containment, and declared-canary exclusion. Do not resolve an
  external credential source to compare it with ordinary prompt text.
- Make CLI text, CLI JSON, and automation explicit owners for non-TUI
  continuity and administration. The TUI returns typed denial for unsupported
  store-wide operations.
- Add bounded current-state snapshots and ordered history pages for durable
  sessions that cannot fit a complete transcript in the M2 snapshot limit.
- Keep Milestone 3 proposed, keep `jido_console-x5b` open for post-audit import
  and graph verification, and block all implementation on the approved M2-E37
  source baseline.
- Allow the local planning baseline and proposed epic specifications to finish
  before M2-E37. Keep Beadwork import, readiness, and implementation blocked
  until that audit approves the exact source.

## [1.2.0] - 2026-08-16

### Added

- Add detailed delivery plans, preconditions, invariants, ordered steps, test
  matrices, and handoffs for the seven open Milestone 2 closeout epics.
- Add M2-E36 to build and prove one exact post-closeout v0.2 production
  candidate.
- Add M2-E37 to audit the post-closeout candidate, reaffirm skipped
  publication, and declare the exact Milestone 3 baseline.
- Add a Milestone 2 proof index that preserves the old records as historical
  evidence and points to the new closeout candidate and audit records.

### Changed

- Make M2-E17 depend directly on M2-E09 so bounded client delivery starts only
  after canonical Jidoka-to-Console projection is complete.
- Separate ownership for canonical projection, bounded delivery, recovery,
  client API, TUI cutover, parity proof, and legacy deletion across M2-E09,
  M2-E17, M2-E18, M2-E26, M2-E27, M2-E31, and M2-E32.
- Define the bounded caller-owned projection cursor, the additive v1 delivery
  family, deprecated gap-event compatibility, and recovery-overflow token
  invalidation.
- Keep M2-E33 and M2-E34 as historical evidence for the earlier source. Require
  M2-E36 and M2-E37 before Milestone 2 closes or Milestone 3 planning starts.
- Increase the Milestone 2 generated epic count from 35 to 37 and synchronize
  the roadmap and Beadwork delivery graphs.

## [1.1.0] - 2026-08-16

### Added

- Add Milestone 3 planning readiness checks for durable-record ownership,
  acknowledgement, recovery topology, session-generation fencing, storage
  evaluation, commit reconciliation, crash injection, and recovery operations.
- Add Milestone 3 work and exit gates for recovery startup, stale-generation
  rejection, bounded storage-writer delivery, client recovery after restart,
  fork authority, and measured recovery limits.
- Add permanent rules that prohibit raw runtime-event client paths, require a
  receiver-side delivery bound, and fence earlier session generations.

### Changed

- Make Milestone 2 require each production client to consume only canonical
  Console protocol data through `Session.Client`.
- Define bounded client delivery as a bound on the receiving mailbox and copied
  payload data, not only sender-side delivery bookkeeping.
- Reserve full snapshots for attach and explicit recovery instead of each
  ordinary live update.
- Add the Milestone 2 closeout and Milestone 3 design handoff to the immediate
  build order.

## [1.0.9] - 2026-08-16

### Changed

- Disable publication while keeping production-candidate proof and quality
  audits mandatory.
- Record M2-E35 as intentionally skipped without a tag, package, archive, or
  public release.
- Require Milestone 3 planning to end in candidate proof and an evidence-only
  quality audit without a publication epic.

## [1.0.8] - 2026-08-15

### Added

- Restore the generated Milestone 1 and Milestone 2 epic sources to `main`.

### Changed

- Defer M1-E30 production publication until 2026-10-01.
- Start M2-E01 and M2-E03 from the approved Milestone 1 source baseline.
- Keep public v0.1 publication separate from the Milestone 2 delivery graph.

## [1.0.7] - 2026-08-14

### Added

- Add 35 generated epics for Milestone 2 under its milestone directory.
- Give each Milestone 2 epic one pull request boundary, acceptance checks,
  proof artifacts, dependencies, and milestone traceability.
- Add a Mermaid diagram that shows the complete Milestone 2 dependency order.
- Add one Beadwork identifier for each Milestone 2 epic.

### Changed

- Link the Milestone 2 milestone to its generated epic index.
- Split the former four broad Milestone 2 groups into reviewable
  one-pull-request delivery units without a change to the milestone outcome or
  exit gate.
- Keep the Jidoka fixes, Console protocol, session ownership, client delivery,
  and current-client migrations in separate pull requests.
- Keep production-candidate proof, release audit, and protected publication in
  separate pull requests.

## [1.0.6] - 2026-08-14

### Added

- Add 30 generated epics for Milestone 1 under its milestone directory.
- Give each Milestone 1 epic one pull request boundary, acceptance checks,
  proof artifacts, dependencies, and milestone traceability.
- Add a Mermaid diagram that shows the complete Milestone 1 dependency order.
- Add one Beadwork identifier for each Milestone 1 epic.

### Changed

- Link the Milestone 1 milestone to its generated epic index.
- Split the former five broad Milestone 1 groups into reviewable
  one-pull-request delivery units without a change to the milestone outcome or
  exit gate.
- Keep the provider, restricted-execution, distribution, golden-workflow, and
  final release-audit boundaries in separate pull requests.
- Keep candidate audit and protected production publication in separate pull
  requests.

## [1.0.5] - 2026-08-14

### Added

- Link each Gate 0 epic to its imported Beadwork epic identifier.
- Add the Beadwork identifiers to the Gate 0 epic index.

### Changed

- Use the `jido_console` prefix for new Beadwork records while preserving the
  closed legacy `jido_console` records.

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
