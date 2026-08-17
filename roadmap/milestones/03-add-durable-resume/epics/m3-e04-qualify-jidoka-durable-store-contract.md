---
epic: M3-E04
type: epic
title: Harden and Qualify the Jidoka Durable Store Contract
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e04
depends_on: [M3-E01]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E04: Harden and Qualify the Jidoka Durable Store Contract

## Goal

Deliver one focused upstream Jidoka pull request that hardens and proves the public store boundary needed for durable resume.

## Scope

- Add public supported-version accessors for `Jidoka.Session.Data` and `Jidoka.Snapshot`, and a public snapshot serialization-prefix accessor.
- Correct the durable-version and codec documents and add a document-drift check.
- Document `Jidoka.Session.Store` and `Jidoka.Session.Transitions` as the approved custom-store boundary.
- Require either no durable callbacks or the complete durable callback set before execution claims work.
- Select recovery state for the active lease request identity, not the last snapshot from another request.
- Freeze the stable checkpoint identity as Jidoka session ID, durable revision, request identity, lease identity, and snapshot ID.
- Add one reusable custom file-store conformance fixture with transaction, sync-before-reply, crash, lease, effect, recovery, and fork proof.

## Out of Scope

- Console storage or recovery code
- A new Jidoka runtime or agent loop
- Private Jidoka module access
- A new Jidoka database adapter
- Console request-metadata policy
- Breaking changes to existing Jidoka callers

## Dependencies

This epic depends on M3-E01. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E01 defines the watermark fields and durable acknowledgement terms.
- The approved local Jidoka source and its public store, transition, lease, recovery, effect, and fork tests are available.

### Decisions and invariants

- This is one Jidoka-repository pull request. It does not change Console source.
- A custom store runs public transition functions inside its own durable transaction and replies only after commit.
- Durable mode is all or none. A partial callback set fails before a claim.
- Recovery selects only the snapshot that belongs to the current lease request.
- The checkpoint link uses public session revision and snapshot identity. No caller uses the undocumented checkpoint callback.
- Jidoka effect intent and result records remain authoritative for safe replay and unsafe-effect uncertainty.
- Do not use `Jidoka.Session.Execution`, `Jidoka.Runtime`, `Jidoka.Adapter`, `Jidoka.Snapshot.Codec`, private store transition helpers, or `:on_durable_checkpoint`.
- A newly found defect outside this declared durable-store boundary needs a separate approved roadmap epic.

### Delivery steps

1. Add `Session.Data.supported_schema_versions/0`, `Snapshot.supported_schema_versions/0`, and `Snapshot.serialization_prefix/0`.
2. Correct the stale durability and codec documents and add the drift check.
3. Add complete-durable-mode validation before claim or resume.
4. Bind recovery snapshot selection to the active lease request.
5. Add a minimal custom file-store fixture that uses public transition functions.
6. Test claim, checkpoint, renew, commit, recover, resume, and fork through the fixture.
7. Test sync-before-reply, commit-before-reply crash, mismatched identity, multi-request crash, and unsafe-effect behavior.
8. Run the existing Jidoka recovery, effect, snapshot, and fork suites.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Custom store | All public transitions work without private calls | Committed revision returned after sync |
| Durable mode | Zero or the complete callback set is accepted | Partial set fails before claim |
| Checkpoint identity | Revision and snapshot identity are stable | Exact request and lease correlation |
| Multi-request crash | Recovery selects the current lease-request snapshot | No older-request snapshot selected |
| Commit before reply | Reload returns the committed value | Same revision and transition identity |
| Unsafe effect | Incomplete unsafe effect stops for reconciliation | No automatic dispatch |
| Compatibility | Session current 3 accepts 1-3; snapshot current 2 accepts 1-2; prefix stays `jidoka:snapshot:v1:` | Future versions fail |

### Completion boundary and handoff

M3-E05 pins the approved Jidoka result. M3-E06 then implements the Console-owned SQLite store adapter against this boundary.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- The three public version and prefix accessors match the code and the documents cannot drift silently.
- The public custom-store boundary is documented and covered by conformance tests.
- The stable checkpoint and watermark fields are named and available without private Jidoka access.
- A store reply occurs only after its durable transaction commits.
- Lease, revision, request, and snapshot checks reject stale or conflicting transitions.
- A partial durable callback set fails before claim, and recovery cannot select a snapshot from another request.
- Completed effects replay and uncertain unsafe effects stop under the existing policy.
- Current schema and codec documentation agrees with the code.
- Existing Jidoka runtime, resume, recover, effect, and fork tests pass.
- No Console code, SQLite adapter, or new execution loop is added.

## Proof Artifacts

- Public Jidoka durability matrix
- Custom-store conformance fixture
- Checkpoint and watermark identity contract
- Schema and codec compatibility record
- Crash, lease, and unsafe-effect results
- Approved upstream Jidoka pull request and immutable merge identity

## Milestone Traceability

This epic supplies the external Jidoka qualification required before Console can claim exact durable execution recovery.
