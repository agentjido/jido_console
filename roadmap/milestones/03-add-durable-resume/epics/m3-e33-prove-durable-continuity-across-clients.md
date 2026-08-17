---
epic: M3-E33
type: epic
title: Prove Durable Continuity Across Clients
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e33
depends_on: [M3-E08, M3-E14, M3-E28, M3-E29, M3-E30, M3-E31, M3-E32]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E33: Prove Durable Continuity Across Clients

## Goal

Prove the full durable operation contract through every production client path with one provider-free corpus.

## Scope

- Add one versioned durable-session fixture corpus and normalized outcome ledger.
- Run the same session-semantic corpus for restart-safe admission, queues,
  permissions, manifests, effects, watermarks, exact resume, transcript-only,
  repair, retry, fork, and history through TUI, automation, text, and JSON
  production entry points.
- Run credential-profile, backup, restore, physical-repair, archive, retention,
  and removal administration through each production entry point that declares
  that capability. Prove typed capability denial for the others, including TUI.
- Measure the frozen storage, queue, snapshot, suffix, history, recovery, and state-tree limits.
- Scan database, WAL, SHM, backups, archives, quarantine, logs, traces, terminal output, and artifacts for credential canaries.
- Extend the release acceptance oracle to run the complete durable workflow.
- Record defects against the owning functional epic; do not fix product behavior here.

## Out of Scope

- Product behavior changes
- Crash-point operating-system kill proof owned by M3-E34
- Candidate packaging
- Publication
- New client surface

## Dependencies

This epic depends on M3-E08, M3-E14, M3-E28, M3-E29, M3-E30, M3-E31, M3-E32. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- All production clients use Session.Client and the continuity operations are complete.
- M3-E08 supplies the hard quota contract. M3-E29 and M3-E30 supply separate archive and removal operations.
- The M2 protocol and client compatibility fixtures remain available.

### Decisions and invariants

- This is proof-only. A failed behavior returns to its owning epic.
- Compare normalized semantic outcomes and side effects, not renderer bytes.
- Use the same injected identifiers, clocks, file faults, provider replay, and expected digests across clients.
- A secret scan covers every file class created during normal, failed, recovered, repaired, archived, and removed flows.
- Persistent-reader and checkpoint-busy cases must hold the WAL and writer stop bounds.
- Qualification time values are observations on the named reference system.

### Delivery steps

1. Create the durable fixture corpus and normalized oracle.
2. Run core receipt, state, resume, operation, and capacity cases through the local client driver.
3. Run the semantic corpus through TUI, automation, text, and JSON. Run the
   administrative corpus through the applicable-client matrix and prove denials.
4. Measure all frozen count, byte, page, reader, WAL, file, queue, recovery, replay, and timing limits.
5. Run default and isolated Jido home cases.
6. Scan all persistent and output surfaces for secret canaries and forbidden values.
7. Add the installed-artifact acceptance entry point and record the proof report.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Acknowledged input | Present exactly once after restart | Same receipt and event identity |
| Exact resume | State equals durable oracle | Verified watermark and new generation |
| Transcript and operations | No false runtime claim; retry, repair, fork, and abandon follow policy | Zero unexpected calls |
| Session clients | Normalized ordered ledger and side effects match | Same semantic fixture and protocol version |
| Administration | Each declared surface passes; other surfaces deny | Frozen applicable-client matrix |
| Limits and secrets | All hard limits pass; zero canary values | Every owned file and output class scanned |
| WAL pressure | A persistent reader cannot bypass stop rules | Reader, 64 MiB stop, and 384 MiB hard bounds |

### Completion boundary and handoff

M3-E34 adds deterministic and operating-system crash proof over this complete workflow. M3-E35 proves upgrade compatibility.

### Risks and controls

- A proof epic can hide a product defect. Stop and return each defect to its owning implementation epic.
- Evidence can mix two source or payload identities. Freeze one manifest and reject mixed results.
- A development checkout can give a false artifact result. Record the exact installed executable and file paths.

## Acceptance Checks

- The provider-free corpora cover every Milestone 3 durable operation.
- All production session clients observe the same ordered semantic outcomes and allowed side effects.
- Administrative operations pass through each declared surface, and every
  undeclared surface returns the typed capability denial.
- Acknowledged input and commands appear exactly once after restart.
- Exact and transcript-only results remain distinct in every client.
- Retry, repair, abandon, fork, archive, and removal follow the operation matrix.
- All frozen count, byte, queue, replay, file, and state-tree limits pass.
- Database-page reserve, WAL, reader age, recovery, diagnostics, history-page, backup, archive, and temporary-file bounds pass.
- Secret scans find zero declared credential-canary values in every Jido-owned
  durable class and every product output class created by the fixture.
- The release acceptance oracle can run the workflow through an installed artifact.
- No product behavior is changed in this epic.

## Proof Artifacts

- Versioned durable fixture corpus
- Cross-client normalized outcome ledger
- Applicable-client capability matrix and denial ledger
- Durable operation matrix result
- Limit and timing measurements
- Default and isolated-home results
- Complete credential-canary scan
- Installed-artifact acceptance oracle

## Milestone Traceability

This epic proves the production-path durable continuity claim before candidate packaging.
