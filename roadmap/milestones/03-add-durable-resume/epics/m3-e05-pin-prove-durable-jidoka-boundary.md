---
epic: M3-E05
type: epic
title: Pin and Prove the Durable Jidoka Boundary
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e05
depends_on: [M3-E04]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E05: Pin and Prove the Durable Jidoka Boundary

## Goal

Pin one immutable Jidoka revision and expose only its approved durable session contracts through the Console runtime boundary.

## Scope

- Update the immutable Jidoka pin to the approved M3-E04 source.
- Expose the approved session, transition, checkpoint, recovery, effect-replay, and fork data through `Jido.Console.Session.Jidoka`.
- Define Console-to-Jidoka session ID mapping and validate it on every durable operation.
- Carry Console receipt identity in one namespaced, canonical JSON-only Jidoka request-metadata map with exact count and byte bounds from M3-E01.
- Add compatibility fixtures for session revision, lease, snapshot, effect, recovery, and fork behavior.
- Strengthen source guards against private Jidoka runtime or adapter access.

## Out of Scope

- The SQLite Jidoka store adapter
- Console event persistence or watermark policy
- Session recovery orchestration
- Changes to Jidoka source
- Client or renderer behavior

## Dependencies

This epic depends on M3-E04. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E04 has one approved immutable Jidoka commit and passing custom-store conformance evidence.
- The M2 Jidoka public-facade and projection boundaries remain valid.

### Decisions and invariants

- Use the approved public Jidoka session and store contracts only.
- Console session ID and Jidoka session ID are equal for a normal session. An imported or forked mapping must be explicit and durable.
- Jidoka lease identity and Console generation are separate fences.
- The Console facade returns bounded identity and status data, not raw provider clients or private runtime state.
- Allow only the named stable data modules and exact public `Jidoka.Session.Transitions` functions. A broad `Jidoka.Session.*` allow-list is not sufficient.
- The SQLite adapter will form its committed transition receipt from the public store callback arguments and committed `Session.Data` result. Console does not reconstruct terminal lease identity later.

### Delivery steps

1. Update the Jidoka source pin and compatibility identity.
2. Extend the Console Jidoka facade with the qualified durable data operations.
3. Add exact session-ID mapping and bounded namespaced request-metadata rules.
4. Add source-boundary checks that reject execution internals, the private snapshot codec, private store helpers, and the undocumented checkpoint hook.
5. Run public checkpoint, recover, resume, effect, and fork fixtures through the facade.
6. Record the exact Jidoka version, schema versions, and supported contract.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Pin | Build uses one immutable Jidoka commit | Moving or local production source rejected |
| Mapping | Console and Jidoka identities match or have an explicit map | Cross-session value rejected |
| Checkpoint | Facade returns revision, request, lease, and snapshot identities | No private struct leakage |
| Metadata | Only the namespaced Console receipt map reaches Jidoka | JSON-only count and byte bounds |
| Recovery | Recover and resume preserve public semantics | No direct store mutation by Console session code |
| Boundary | Source scan permits only approved public modules | Private calls fail the check |

### Completion boundary and handoff

M3-E06 uses this facade and the public Jidoka store behavior. M3-E15 and M3-E16 use its effect and checkpoint identities.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- The product pins the exact approved Jidoka revision.
- Every normal durable session has one validated Console-to-Jidoka identity mapping.
- Console receipt metadata reaches Jidoka without credential or unbounded data.
- The facade exposes all and only the qualified durable identity and transition data.
- Lease and generation identities remain distinct.
- Durable compatibility fixtures pass against the exact pin.
- Production source contains no private Jidoka durability access.
- Production source does not use `:on_durable_checkpoint` or reconstruct a cleared terminal lease from a terminal session value.
- No SQLite adapter or recovery policy is implemented.

## Proof Artifacts

- Immutable Jidoka identity record
- Console facade contract
- Session mapping fixtures
- Checkpoint, recovery, effect, and fork compatibility results
- Public API source-boundary scan

## Milestone Traceability

This epic integrates the approved Jidoka durability boundary without making Console a second execution runtime.
