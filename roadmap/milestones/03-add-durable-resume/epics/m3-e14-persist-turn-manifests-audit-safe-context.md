---
epic: M3-E14
type: epic
title: Persist Turn Manifests and Audit-Safe Context
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e14
depends_on: [M3-E10, M3-E11, M3-E12, M3-E13]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E14: Persist Turn Manifests and Audit-Safe Context

## Goal

Persist the exact data identity needed to explain, restore, and safely continue one durable turn.

## Scope

- Persist provider, model, variant, generation settings, agent specification, prompt, tool schema, skill schema, extension descriptor, and protocol identities.
- Persist coding profile, workspace identity, accepted workspace-state digest, execution-environment identity, credential-profile version, and selected reference identity.
- Detect missing or incompatible identities and workspace drift before continuation.
- Build a bounded model-context projection with its exact source event range and digest.
- Build a portable, redacted audit view from authoritative records.
- Keep canonical history immutable when context is compacted.
- Scan all persisted and exported values for credential canaries and forbidden runtime data as defense-in-depth evidence after the M3-E11 entry control.

## Out of Scope

- Credential value storage or a new secret-store backend
- Model or tool execution
- Canonical event deletion
- Client transcript paging
- Remote audit upload

## Dependencies

This epic depends on M3-E10, M3-E11, M3-E12, M3-E13. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream client, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E10 provides immutable canonical history.
- M3-E11 and M3-E12 provide exact request, queue, interaction, and permission identities.
- M3-E13 provides immutable credential-profile, version, and selected-reference identities.
- Current provider, model, coding, environment, and extension registries can supply stable descriptor identities.

### Decisions and invariants

- A durable turn stores stable identities, normalized settings, and digests, not live modules, functions, provider clients, or credentials.
- A credential profile or reference can restore configuration identity but grants no authority. Resolution happens at the final execution boundary.
- Workspace drift blocks exact continuation until an explicit approved operation resolves it.
- Model context is derived and bounded. Its source range and digest make it rebuildable.
- The audit digest chain detects mutation but does not claim a signature against the current local user.

### Delivery steps

1. Add the durable turn and invocation manifest records.
2. Add registry resolution and compatibility checks for every identity.
3. Add workspace-state acceptance and drift results.
4. Add bounded context projection and deterministic rebuild.
5. Add portable redacted audit projection and offline chain verification.
6. Add recursive secret and forbidden-value scans.
7. Add restart, drift, missing-descriptor, compact-context, and tamper fixtures.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Turn identity | All provider, model, setting, prompt, tool, and skill identities restore | Exact digests match |
| Workspace | Accepted digest matches or returns typed drift | No silent continuation |
| Credential | Only profile, version, selected reference, and provider identity persist | Canary value and value fingerprint absent |
| Context | Rebuild gives same bounded prompt projection | Canonical history unchanged |
| Audit | Mutation, deletion, insertion, or reorder is detected | No secret or process value |

### Completion boundary and handoff

M3-E15 uses the exact manifest and permission identity before each effect. M3-E22 requires this manifest for exact resume. M3-E26 links fork lineage to it.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the durable owner. Add structural and runtime boundary checks.
- A crash test can miss the critical window. Use deterministic barriers and record each acknowledged operation ID.

## Acceptance Checks

- Every durable turn names the exact provider, model, variant, settings, prompt, tool schema, and skill schema.
- Workspace and execution-environment identities survive restart and drift is explicit.
- Only credential profile and reference identities persist, and a missing or changed identity stops before provider or tool work.
- Context compaction stays within its limit and does not remove canonical history.
- Rebuilding the context and audit views from the same source gives the same result.
- Audit export is portable JSON-compatible data with origin, trust, generation, watermark, and fork fields.
- Credential and forbidden-value scans find zero prohibited values.
- No model, tool, client, or credential-store behavior is added.

## Proof Artifacts

- Durable turn-manifest schema
- Identity and compatibility matrix
- Workspace drift fixtures
- Context compaction equivalence and size result
- Portable audit verification result
- Credential-canary and forbidden-value scans

## Milestone Traceability

This epic supplies durable model identity, immutable audit provenance, and bounded prompt context.
