# Foundation and Semantic Core Backlog

## BASE-001: Record deterministic session fixtures

- Stage: Gate 0
- Priority: high
- Work: Record redacted terminal, JSONL, semantic event, model-result, tool-result, and provider-free replay fixtures. Run the clean baseline two times with isolated build and Git state.
- Acceptance: Both runs produce the same semantic result. Replay needs no paid model call and reports prompt, call, tool, or event divergence.

## BASE-002: Freeze the golden coding-task fixture

- Stage: Gate 0; release proof in Phase 1
- Priority: high
- Work: Define one deterministic repository task with discovery, read, search, edit, command, test, exact diff, approval, rejection, cancellation, and current-run revert paths.
- Acceptance: The fixture has exact initial state, recorded model and tool results, expected effects, expected diff, rejection state, and revert state. Phase 1 can run it through the production artifact.

## DIST-001: Publish the npm native CLI packages

- Phase: 1
- Priority: high
- Work: Publish `@agentjido/jido-console` as an entry package and an exact-version macOS ARM64 target package. Put the complete native Mix release in the target package and select it through optional dependencies.
- Acceptance: Global and local installation works through npm scripts, `npm exec`, and `npx jido`. The launcher forwards input, output, signals, and exit status. npm does not compile Erlang or Elixir and does not download a release through an install script.

## DIST-002: Publish the platform-by-channel support matrix

- Phase: 1
- Priority: high
- Work: Publish exact supported platform and distribution-channel cells. Require macOS ARM64 through direct archive, Homebrew, and npm for v0.1. Keep untested cells outside the support claim.
- Acceptance: Every claimed cell passes install, first run, update, and removal. All cells use the same native payload, version, license, checksums, software bill of materials, and provenance.

## PROVIDER-001: Publish tested provider and model support

- Phase: 1
- Priority: high
- Work: Support OpenAI, Anthropic, and Google Gemini. Add Ollama as beta only after its beta contract passes. Keep exact `provider:model` selection separate from the larger ReqLLM catalog.
- Acceptance: Each support claim passes streaming, tool-call, multiple-turn tool, structured-result, cancellation, timeout, usage, cost, prompt-cache, and error-normalization checks for every claimed feature.

## PROVIDER-002: Add model discovery and testing

- Phase: 1
- Priority: high
- Work: Add `jido models list`, `jido models show provider:model`, and `jido models test provider:model` with supported, beta, available, and unsupported tiers.
- Acceptance: Commands show exact identity, tested capabilities, limits, cost data, last contract result, and known gaps without exposing a credential.

## PROVIDER-003: Enforce model capability and fallback policy

- Phase: 1
- Priority: high
- Work: Match required features before a turn, block every model network call in offline mode, and require consent before fallback changes provider, data boundary, cost class, or capability.
- Acceptance: An unsupported feature fails before execution with an exact reason. Offline tests observe no network model call. A boundary-changing fallback cannot occur without a recorded decision.

## AUTH-001: Resolve v0.1 credentials safely

- Phase: 1
- Priority: high
- Work: Define the stable environment contract. Resolve provider credentials from official variables and native chains. Add `jido auth status` and `jido auth doctor`. Load an environment file only when selected and private.
- Acceptance: Host variables take precedence over an explicit environment file. No command accepts `--api-key`. Status, errors, logs, events, traces, and artifacts never contain a credential value.

## LOCAL-001: Establish the Jido home contract

- Phase: 1
- Priority: high
- Work: Add one path resolver with `JIDO_HOME` and `~/.jido`. Define `config.toml`, `state/`, `logs/`, `artifacts/`, `cache/`, and `run/` with permission, migration, backup, and removal rules.
- Acceptance: Product code does not construct these paths outside the resolver. Tests isolate all state with `JIDO_HOME`. Update and removal do not lose data without explicit consent.

## LOCAL-002: Make coding changes reviewable and reversible

- Phase: 1
- Priority: high
- Work: Bind exact diffs, approval, rejection, and current-run revert to the starting workspace identity and accepted effects.
- Acceptance: Rejection leaves the workspace unchanged. Current-run revert restores the recorded pre-run state without undoing unrelated user changes.

## CORE-001: Return typed command effects

- Phase: 2
- Priority: high
- Work: Define a closed set of semantic command effects. Convert effects to client outcomes at the client boundary.
- Acceptance: A command test has no renderer or transport dependency.

## CORE-002: Own one command registry

- Phase: 2
- Priority: high
- Work: Put names, aliases, argument schemas, help, permissions, provenance, and client descriptors in one registry.
- Acceptance: Help, validation, permission checks, and client command lists use the same declaration.

## CORE-003: Classify event durability and sensitivity

- Phase: 2
- Priority: high
- Work: Mark each event as durable, transient, or client-local and mark fields that local and portable telemetry can retain.
- Acceptance: The policy rejects an event without a class. Draft input and secret content do not enter durable telemetry.

## CORE-004: Separate model and view result data

- Phase: 2
- Priority: high
- Work: Give tool results concise model content and typed view details.
- Acceptance: A rich client can render a result without parsing model prose.

## CORE-005: Define the permission life cycle

- Phase: 2
- Priority: high
- Work: Define request identity, principal, rule, control, effect, decision scope, response, expiry, cancellation, audit integrity, and resume data.
- Acceptance: One approval cannot satisfy a different control or changed effect. The contract supports allow once, session scope, persistent allow, deny, expiry, and cancellation without polling.

## CORE-006: Define the extension and hook contract

- Phase: 2
- Priority: high
- Work: Define stable extension types, capability declarations, hooks, and one failure policy for each hook.
- Acceptance: An extension does not use private host modules. An authority hook fails closed.

## CORE-007: Define exact model invocation identity

- Phase: 2
- Priority: high
- Work: Bind each session and turn to provider, model, variant, generation settings, profile, prompt identity, tool schema, skill schema, and fallback attempt identity.
- Acceptance: A semantic event can state the complete effective model invocation without a credential value. A model change is an explicit operation.
