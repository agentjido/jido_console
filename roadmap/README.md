# Jido Console Roadmap

Roadmap version: **1.2.0**

Roadmap status: **proposed**

## Product Decision

- Product: Jido Console
- Repository and package: `jido_console`
- OTP application: `:jido_console`
- Main namespace: `Jido.Console`
- User command: `jido`
- Runtime foundation: Jidoka
- Publication policy: disabled; build and audit candidate artifacts only

The current `jido_console` code is the implementation base. Tilde supplies reviewed architecture and renderer patterns. Tilde is not a runtime dependency.

## Product Vision

Jido Console is a local control plane for reliable coding agents. It runs supported models, controls tools, keeps acknowledged work alive, isolates effects, compares parallel results, and recovers sessions with an exact statement of retained state.

The first product is a safe, local, multi-model coding harness for one operator. The product expands in this order:

1. Safe local coding.
2. Durable single-user sessions.
3. Reliable supervised multi-agent work.
4. Local multi-view operation.
5. Isolated and remote execution.
6. Authenticated remote access.
7. Multi-user collaboration.
8. Controlled live extension.

BEAM is the technical advantage, not the user claim. Users must see the advantage as fault isolation, controlled concurrency, durable state, fast recovery, and live inspection.

```text
Terminal | Automation | Local LiveView | Remote Web | SSH
                            |
                 versioned client protocol
                            |
              Jido.Console.Session.Server
                            |
          sequenced semantic events and receipts
                            |
              Jido.Console.Runtime.Jidoka
                            |
                         Jidoka
                            |
      models, effects, tools, agents, and executors
```

Jidoka owns execution truth. Jido Console owns user-visible session truth. One durable watermark connects the two truths. A renderer or transport owns neither truth.

## Roadmap Sequence

Gate 0 is a readiness milestone. Every numbered directory in `roadmap/milestones/` is one quality milestone. It must produce a working, installable candidate and complete evidence. Publication is a separate maintainer decision and is disabled.

| Stage | File | Main result | Quality target |
| --- | --- | --- | --- |
| Gate 0 | [Establish release readiness](milestones/00-establish-release-readiness/milestone.md) | Repeatable evidence and an owned delivery graph | No release |
| Milestone 1 | [Ship the trustworthy local kernel](milestones/01-ship-trustworthy-local-kernel/milestone.md) | Safe local multi-model coding | v0.1 |
| Milestone 2 | [Ship the supervised session plane](milestones/02-ship-supervised-session-plane/milestone.md) | One owner and one protocol for all current clients | v0.2 |
| Milestone 3 | [Add durable resume, fork, and audit](milestones/03-add-durable-resume/milestone.md) | Restart-safe acknowledged state | v0.3 |
| Milestone 4 | [Add supervised multi-agent work](milestones/04-add-supervised-multi-agent-work/milestone.md) | Durable child agents and owned worktree lanes | v0.4 |
| Milestone 5 | [Add the local LiveView workbench](milestones/05-add-local-liveview-workbench/milestone.md) | Loopback-only single-user web workbench | v0.5 |
| Milestone 6 | [Add isolated local executors](milestones/06-add-isolated-local-executors/milestone.md) | Location-neutral restricted local adapters | v0.6 |
| Milestone 7 | [Add managed and remote executors](milestones/07-add-managed-and-remote-executors/milestone.md) | Trusted nodes and remote work with explicit custody | v0.7 |
| Milestone 8 | [Add authenticated remote access](milestones/08-add-authenticated-remote-access/milestone.md) | Single-operator remote web and SSH access | v0.8 |
| Milestone 9 | [Add multi-user collaboration](milestones/09-add-multi-user-collaboration/milestone.md) | Authorized shared resources and convergent editing | v0.9 |
| Milestone 10 | [Add controlled live extension](milestones/10-add-controlled-live-extension/milestone.md) | Reviewed extension, migration, recovery, and rollback | v0.10 |

Each milestone depends on the prior milestone. A milestone can start only after its dependencies and readiness checks pass. Internal build stages belong in generated epics and Beadwork. They are not separate roadmap milestones.

The `milestone.md` file is the roadmap milestone item. It owns the goal, outcome, work boundary, exclusions, exit gate, and release effect. Epics are generated from the approved milestone and live in its `epics/` directory. Each generated epic is delivered in one pull request. Beadwork owns implementation tasks, task dependencies, assignment, and status.

## Immediate Build Order

1. Pass Gate 0 and link the Milestone 1 delivery graph.
2. Land the Milestone 1 Jidoka policy and execution contracts. Keep later Jidoka changes in their owning quality milestones.
3. Rename the product and establish Jido home, provider, model, credential, and release contracts.
4. Make restricted execution the default and pass the production-artifact golden coding task.
5. Add the semantic protocol, one supervised session owner, and current-client migration as one v0.2 quality target.
6. Complete the Milestone 2 closeout chain: canonical projection, bounded delivery, gap recovery, the final client contract, TUI migration, production-path parity, and legacy deletion.
7. Requalify one exact post-closeout v0.2 artifact and complete the final evidence-only audit. Milestone 3 cannot start from the historical pre-closeout candidate or audit.
8. Before Milestone 3 epic generation, freeze the durable-record inventory, acknowledgement rule, recovery topology, session-generation fence, storage evaluation, commit-reconciliation state machine, and crash matrix.
9. Add restart-safe input, the shared Console-to-Jidoka watermark, and exact recovery.

## Common Milestone Release Gate

This is a source-quality gate. It does not authorize or require publication. Every numbered milestone must pass these checks in addition to its milestone-specific gate:

- Build one production-candidate artifact from a clean checkout.
- Install, start, update, and remove the candidate artifact for each platform and channel pair in the support claim.
- Run all earlier candidate workflows and compatibility fixtures.
- Demonstrate the new milestone outcome through the production artifact.
- Produce a runnable quick start and one complete workflow for the new capability.
- Record failure, cancellation, recovery, and cleanup evidence for each new owned process or external boundary.
- Record the support matrix, known limits, security boundary, and rollback or repair path.
- Pass deterministic tests, package quality gates, dependency checks, secret checks, and release checks.
- Show that no known critical defect invalidates the quality claim.
- Link the roadmap milestone, generated epics, Beadwork work graph, proof artifacts, and quality record.

A milestone is complete only when the working candidate and its evidence exist. A merge, internal architecture stage, or demonstration from a development checkout is not enough. Do not create a tag, GitHub release, archive publication, Homebrew publication, or npm publication unless a later maintainer decision enables publication.

## Platform and Channel Policy

Use an explicit platform-by-channel matrix. A blank matrix cell is not a support claim.

The required v0.1 candidate checks are:

| Platform | Direct archive | Homebrew | npm |
| --- | --- | --- | --- |
| macOS ARM64 | Required | Required | Required |

All channel candidates must wrap the same tested native payload. Add another platform or channel pair only after its native payload passes the common and platform-specific gates.

## Permanent Architecture Rules

1. Jidoka is the only agent runtime.
2. Jido Console is local-first and restricted by default.
3. Jido Console has one semantic session model and one live owner for each session.
4. A renderer is a projection. It is not a source of truth.
5. A transport translates input and outcomes. It does not own behavior or grant authority.
6. Console events have stable sequences and JSON-compatible durable forms.
7. Jidoka checkpoints and Console events share one defined durable watermark and reconciliation contract.
8. Client-local input and navigation do not enter shared session state.
9. Automation contracts stay versioned and stable.
10. Erlang distribution is for trusted nodes. It is not a security sandbox.
11. Untrusted work uses a restricted external boundary.
12. Every numbered roadmap milestone ships a working release.
13. Use OTP and runtime primitives when they meet the need. Add an abstraction only for a stable contract or policy.
14. Admit process-lifetime input before wake-up in Milestone 2. Admit restart-safe input and its receipt before wake-up in Milestone 3.
15. Keep canonical history immutable. Compaction is a prompt projection.
16. Keep model-facing tool content separate from structured view data.
17. Give each session, worktree, project cache, executor, and protocol one named owner.
18. Bind capabilities to the session, principal, lane, and client surface. Do not infer authority from host, origin, or transport.
19. Each runtime and client adapter publishes its ownership, capability, trust, and support contract.
20. Real-time collaboration applies only to declared shared resources. Private drafts remain client-local.
21. All local product paths resolve through one Jido home. `JIDO_HOME` overrides `~/.jido`.
22. Durable state, diagnostic logs, artifacts, disposable cache, and process-local files use separate locations.
23. ReqLLM access does not mean Jido Console support. A support claim needs declared contract evidence.
24. Never change the selected model silently. A trust, cost, or capability boundary change needs consent.
25. Record exact model, settings, prompt, tool-schema, and skill-schema identity for a durable turn.
26. Credential values do not enter configuration, durable state, events, logs, traces, artifacts, or command arguments.
27. Tools, agents, and executors receive an explicit environment and credential allowlist.
28. A trusted-workspace mode is not a sandbox and cannot satisfy a restricted-execution claim.
29. Homebrew, npm, and direct archives wrap the same tested native payload.
30. Tilde remains a reviewed source reference unless a new decision changes that boundary.
31. A client consumes canonical Console protocol data. It never consumes a raw Jidoka or runtime event stream.
32. A client-delivery bound includes the receiving process mailbox and copied payload data. Bounded sender bookkeeping alone is not sufficient.
33. Recovery fences results from every earlier session generation and does not expose a ready session or wake execution before reconciliation completes.

## Release Evidence Policy

Each release must include evidence that matches its claims:

- Test only the platform and channel pairs that the support matrix claims, and test every claimed pair.
- Publish provider, model, executor, client, and recovery support tiers from contract evidence.
- Use recorded provider results for normal tests and explicit bounded live contracts for supported providers.
- Publish a complete user workflow, not only packaging or unit-test results.
- Show the declared safety boundary with hostile fixtures and canary secrets.
- Show failure and recovery at each new commit, process, network, and custody boundary.
- Use measured Jido Console results before a performance, reliability, maintenance, or extension claim.
- Separate product evidence from general claims about Elixir or BEAM.

## Source Allocation

Keep these parts from the current Jido Console:

- Command parsing and the `jido` executable
- Automation schemas, evaluation matrix, JSONL contracts, exit status, and artifacts
- Trusted coding packs and local coding operations after the restricted boundary is proven
- Terminal input, output, resource cleanup, and OTP 28 adapter
- Current TUI rendering and streaming behavior
- Escript, OTP release, package metadata, CI, and release checks

Integrate these reviewed ideas from Tilde:

- Semantic sessions and ordered Console events
- Explicit assistant lifecycle
- Transport-neutral interactions and outcomes
- Named supervised session servers
- Client attach, detach, subscription, snapshot, and replay
- Renderer-neutral transcript blocks, widgets, workbench state, and actions
- LiveView and SSH renderer patterns after their owning milestones start
- Cross-client behavior tests

Do not reuse Tilde file tools, bash execution, session identity, storage lifecycle, `/clear`, `/compact`, demo authentication, or OpenRouter-only runtime gating without redesign.

## Work Not on the Current Critical Path

- Public cloud hosting
- Mobile clients
- Anonymous shared sessions
- Untrusted work on a distributed BEAM node
- Direct load of model-generated code
- QuackDB as a required dependency
- A second tool registry or agent loop
- A large extension marketplace

## Version Control Process

The version at the top of this file is the current roadmap version. Record each version in [`CHANGELOG.md`](CHANGELOG.md).

- Use a major increase for a substantial direction or milestone-structure change.
- Use a minor increase for a milestone, outcome, dependency, or exit-gate change.
- Use a patch increase for text that does not change an outcome.
- Update `last_updated_in` in each changed `milestone.md` file.
- Make one logical change in each Git commit.
- Tag approved roadmap versions as `roadmap-vX.Y.Z`.

Allowed milestone status values are `proposed`, `ready`, `in_progress`, `completed`, and `blocked`.
