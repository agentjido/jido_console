---
epic: M3-E31
type: epic
title: Add CLI, Text, JSON, and Automation Continuity Operations
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e31
depends_on: [M3-E17, M3-E19, M3-E20, M3-E24, M3-E25, M3-E26, M3-E28, M3-E29, M3-E30]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E31: Add CLI, Text, JSON, and Automation Continuity Operations

## Goal

Expose durable session discovery and continuity operations without breaking published automation contracts.

## Scope

- Add versioned CLI text, CLI JSON, and automation operations for session list,
  status, open, exact resume, transcript-only resume, retry, fork, semantic
  repair, abandon, backup, restore, physical repair, archive, and removal.
- Add secret-free credential-profile list, show, create-version, disable, and
  status operations that accept metadata and references only.
- Route every operation through Session.Client or the owned administrative facade.
- Return one typed result that states whether the operation can call a model or tool.
- Preserve automation command schemas, JSONL writer ownership, artifacts, exit status, and one fresh session per evaluation cell.
- Add explicit idempotency keys to mutating automation operations.
- Expose recovery phases, limits, uncertainty, storage capacity, and repair choices as bounded data.
- Keep all durable store files and evidence under the selected isolated Jido home.

## Out of Scope

- TUI rendering
- Remote API or transport
- Breaking automation schema changes
- A second JSONL writer
- Automatic retry, repair, or transcript fallback

## Dependencies

This epic depends on M3-E17, M3-E19, M3-E20, M3-E24, M3-E25, M3-E26, M3-E28, M3-E29, M3-E30. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E24 through M3-E26 supply repair, retry, and fork operations.
- M3-E28 supplies restart attach and continuity status.
- M3-E17, M3-E19, and M3-E20 supply backup, restore, and physical-repair operations.
- M3-E29 and M3-E30 supply archive, retention, and explicit removal behavior.
- The M2 automation compatibility fixtures are frozen.

### Decisions and invariants

- CLI command names and results map the renderer-neutral operations that their
  functional epics already define. This epic does not own a new shared registry
  or Session.Client operation.
- Read-only operations cannot wake execution. Mutating operations state their model and tool policy before they run.
- Automation JSONL and artifacts remain under their existing owner.
- Automation can create a fresh durable session for a cell, but cells never share state unless an explicit future contract says so.
- A failed exact resume cannot select transcript-only automatically.

### Delivery steps

1. Map the existing operation and result declarations into CLI text, CLI JSON, and automation adapters.
2. Add session discovery, credential-profile metadata, and bounded status output.
3. Add exact, transcript-only, retry, fork, repair, abandon, and maintenance operations.
4. Route mutating operations through durable receipts and idempotency keys.
5. Preserve automation schemas, JSONL, artifacts, and exit codes.
6. Add provider-free CLI text, CLI JSON, and automation fixtures for success, blocked, capacity, crash, and restart cases.
7. Add source guards against direct store, server, or Jidoka access.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Read-only commands | No provider, tool, or wake call | Bounded output |
| Mutating command repeat | Same key returns same result | No duplicate session or receipt |
| Exact unavailable | Typed choices return | No transcript fallback |
| Text, JSON, and automation compatibility | Frozen output, JSONL, artifact, and exit-status fixtures pass | One fresh session per cell |
| Boundary | Only public client or administration facade used | No raw store or runtime access |

### Completion boundary and handoff

M3-E33 runs the applicable semantic and administrative corpora through CLI
text, CLI JSON, and automation. M3-E36 later reruns them through the installed
artifact.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- CLI text, CLI JSON, and automation expose each planned continuity and
  maintenance operation and the secret-free credential-profile workflow.
- Each result states whether it can call a model or tool.
- Mutating operations are durable and idempotent.
- Exact and transcript-only modes remain explicit.
- Automation schemas, JSONL ownership, artifacts, exit statuses, and cell isolation remain compatible.
- Recovery, capacity, uncertainty, and repair data is bounded and JSON-compatible.
- Provider-free restart workflows pass.
- No direct Session.Server, storage writer, SQLite, or raw Jidoka path is added.

## Proof Artifacts

- CLI text, CLI JSON, automation, and typed-result matrix
- Operation model/tool policy table
- Automation compatibility result
- Idempotent command fixtures
- Provider-free restart workflow
- Source-boundary scan

## Milestone Traceability

This epic makes durable continuity usable from every current non-TUI production
entry point while preserving published automation behavior.
