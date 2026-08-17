---
epic: M3-E02
type: epic
title: Qualify SQLite for the Local Store
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e02
depends_on: [M3-E01]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E02: Qualify SQLite for the Local Store

## Goal

Prove that one directly declared SQLite adapter can satisfy the file-only durability and packaging contract.

## Scope

- Select one maintained Elixir SQLite adapter as a direct runtime dependency.
- Prove the adapter in development, test, escript, and the supported macOS ARM64 native release.
- Verify WAL, `FULL` synchronous commits, foreign keys, the 250 ms busy timeout, 4,096-byte pages, 32 MiB writer cache, 8 MiB reader caches, 512 MiB SQLite heap cap, incremental vacuum, page limits, backup, and integrity operations.
- Verify the 32 MiB checkpoint target, 64 MiB normal-write stop, 384 MiB WAL limit, 1-second reader-age limit, and checkpoint-busy stop rule.
- Verify that database, WAL, SHM, SQLite temporary, application temporary, and backup files stay in the isolated Jido home.
- Record the completed roadmap-level SQLite, DETS, DuckDB, and plain-file
  comparison as input, then qualify one direct SQLite adapter against the frozen
  criteria.
- Measure commit, checkpoint, open, close, backup, and crash behavior with provider-free data.

## Out of Scope

- The production session schema
- Jidoka store adapter
- Storage writer or supervision
- Session recovery
- A second database engine

## Dependencies

This epic depends on M3-E01. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E01 freezes file paths, durability terms, limits, and required store operations.
- The supported release build and offline packaging fixtures are available.

### Decisions and invariants

- Use a direct SQLite adapter. Do not add Ecto and do not call the host `sqlite3` executable.
- Accept an adapter only if it works inside the final native payload and does
  not write outside `JIDO_HOME`. If no adapter passes, return a roadmap blocker;
  do not select a different engine in this pull request.
- Use WAL with `synchronous=FULL`; a weaker mode cannot satisfy durable acknowledgement.
- Use one database file with a hard page limit. DuckDB and DETS remain comparison fixtures only.
- Use `temp_store=MEMORY` for bounded normal queries. A selected adapter operation that can spill must route its temporary file to the versioned state root before the first connection.
- Reject an adapter or operation that can fall back to `/tmp`, `TMPDIR`, a workspace, `cache/`, or `run/`.

### Delivery steps

1. Verify the frozen engine evaluation record and record the selected SQLite adapter version and license.
2. Add the adapter as a direct runtime and release dependency.
3. Add a minimal isolated-home database probe with the frozen pragmas, page reserve, reader limit, and temporary-store policy.
4. Add commit-before-reply, process-kill, application-kill, disk-full, and reopen probes.
5. Hold a reader across checkpoints and prove the checkpoint-pending, normal-write-stop, reader-interrupt, and checkpoint-blocked states.
6. Add bounded sort, migration, backup, integrity, restore, repair, and recovery-load probes while monitoring every created file.
7. Run the probe through escript and the native release fixture.
8. Record latency, memory, file, sidecar, package, and crash results.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Package | Adapter loads in development, escript, and native release | No host executable or network service |
| Durability | Committed row survives process and operating-system kill | `FULL` synchronous mode verified |
| Paths | All database sidecars and temporary files stay in the state root | Zero external file path |
| Capacity | Page reserve and WAL limits are enforced | 864 MiB normal page ceiling; 1 GiB database; 384 MiB WAL |
| Busy checkpoint | A persistent reader cannot cause unbounded WAL growth | 1-second reader age; normal writes stop at 64 MiB |
| Temporary work | Sort and every maintenance probe stays in the state root | 512 MiB SQLite heap; 64 MiB application temporary aggregate |
| Backup | Online backup reopens with the same digest | Source remains writable only after barrier release |

### Completion boundary and handoff

M3-E06 uses only the qualified adapter and settings. If package or crash proof fails, M3-E06 remains blocked.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- The selected adapter is a direct declared dependency with a recorded license and version.
- The supported native artifact can open, commit, close, and reopen the isolated database.
- All required pragmas are set and verified at open.
- The 250 ms busy timeout leaves time for the 1-second public deadline and returns `timeout_unknown` when commit state cannot be known.
- A committed row survives the declared crash probes.
- Database, WAL, SHM, backup, and temporary files stay inside `JIDO_HOME/state/sessions/v1`.
- The active database, page reserve, WAL, reader, and temporary-data limits are measurable and enforced.
- A busy or persistent reader cannot grow the WAL beyond its hard limit, and a blocked checkpoint preserves the live WAL for storage recovery.
- The frozen comparison record explains why SQLite is selected. This epic adds
  only adapter qualification and does not reopen engine selection.
- No production durable session table or recovery path is added.

## Proof Artifacts

- Verification of the frozen storage evaluation matrix
- SQLite adapter and packaging identity
- Pragma verification result
- Crash durability probe
- Isolated-home path inventory
- Capacity and WAL measurements
- Persistent-reader and checkpoint-busy result
- Temporary-file and query-memory result
- Backup and integrity result

## Milestone Traceability

This epic selects and qualifies the direct adapter for the SQLite storage
decision that roadmap planning already made.
