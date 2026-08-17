---
epic: M3-E29
type: epic
title: Archive and Retain Durable Sessions
status: proposed
milestone: milestone-3
beadwork_id: jido_console-m3e29
depends_on: [M3-E08, M3-E20, M3-E26]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.1
---

# M3-E29: Archive and Retain Durable Sessions

## Goal

Move terminal or abandoned session history from the active database to one verified, bounded local archive without losing audit or fork ancestry.

## Scope

- Compact only rebuildable indexes, snapshots, and safe SQLite free pages automatically.
- Archive a terminal or abandoned session to canonical Console JSONL, one checksum-protected opaque Jidoka value when execution evidence exists, and a verified manifest below `JIDO_HOME`.
- Reserve the source-plus-archive high-water bytes before archive staging.
- Verify Console order, Jidoka schema and digest, record counts, chain heads, watermarks, lineage, size, and private modes.
- Commit a two-phase archive decision before active Console and Jidoka rows are removed.
- Protect parent history or a verified archived copy while a fork depends on it.
- Enforce at most 128 archive sets, 256 MiB per set, and 512 MiB aggregate.
- Keep archives until an explicit M3-E30 removal. Do not delete an archive automatically.

## Out of Scope

- Destructive removal of every retained copy
- Remote or cloud archive
- Archive export outside `JIDO_HOME`
- Automatic deletion of authoritative history
- Changing the hard v0.3 limits
- Exact resume or rehydration from an archive

## Dependencies

This epic depends on M3-E08, M3-E20, M3-E26. These dependencies supply quota control, physical integrity checks, and durable fork lineage.

## Pull Request Boundary

Deliver this epic in exactly one pull request. It delivers only derived compaction, archive staging, verification, adoption, active-row cleanup after adoption, and fork-safe retention. It must not add destructive removal, client, proof, candidate, audit, or publication work.

## Detailed Delivery Plan

### Preconditions

- M3-E08 accounts for database, archive, and staging bytes.
- M3-E20 can verify physical and authoritative heads before archive.
- M3-E26 identifies each parent, child, fork boundary, and required ancestor.

### Decisions and invariants

- A canonical archive is retained audit and lineage evidence, not a disposable cache or exact-resume authority.
- Active rows remain authoritative until the complete archive and manifest verify and the archive decision commits.
- Automatic maintenance removes only rebuildable data and safe free pages.
- Fork ancestry must remain available in the active store or one verified archive.
- No automatic policy deletes an archive.

### Delivery steps

1. Add bounded derived-data compaction and incremental-vacuum operations.
2. Add canonical Console JSONL, opaque Jidoka value, and manifest codecs.
3. Reserve source, stage, and final archive high-water bytes.
4. Add two-phase archive staging, full verification, adoption, and decision commit.
5. Remove active rows only after the archive decision commits.
6. Add fork-ancestor reference checks and archive adoption after restart.
7. Add capacity, interrupted archive, duplicate set, tamper, fork, and cleanup tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Derived compaction | Rebuild gives the same result | Authoritative digests unchanged |
| Archive | Console replay and opaque Jidoka decode match the active source | Exact session, schema, and chain heads |
| Archive crash | Active source or verified archive remains authoritative | No partial-only state |
| Fork ancestry | Child keeps one verified parent boundary | No broken lineage |
| Capacity | Archive stops before staging if it cannot fit | 256 MiB set; 512 MiB aggregate |

### Completion boundary and handoff

M3-E30 removes active and session-specific retained copies only after every
containing whole-store backup or quarantine image retires through its separate
operation. M3-E31 exposes archive operations through CLI text, CLI JSON, and
automation. M3-E33 proves retention through the applicable-client matrix.

### Risks and controls

- Active cleanup can happen too early. Require verified archive and committed decision first.
- Archive data can exceed limits. Reserve the full high-water size and stop at the per-set bound.
- Parent cleanup can break a child. Verify lineage references before each row removal.

## Acceptance Checks

- Automatic maintenance changes only derived data and safe free pages.
- Archive output is canonical Console JSONL, the optional opaque Jidoka value, and a private verified manifest below `JIDO_HOME`.
- The archive includes the checksum-protected opaque Jidoka value when execution evidence exists.
- Active Console and Jidoka rows remain until the archive verifies and its decision commits.
- Interrupted archive leaves an active source or one complete verified archive.
- Fork ancestry remains valid after active cleanup.
- Archive use cannot exceed 128 sets, 256 MiB per set, or 512 MiB aggregate.
- No archive is deleted automatically.
- No destructive removal of all retained copies is part of this epic.

## Proof Artifacts

- Derived compaction equivalence
- Archive Console JSONL, Jidoka value, and manifest schemas
- Two-phase archive trace
- Interrupted archive matrix
- Fork-ancestry retention result
- Archive count and byte measurements

## Milestone Traceability

This epic bounds retained local history and preserves it through a verified archive before active-store cleanup.
