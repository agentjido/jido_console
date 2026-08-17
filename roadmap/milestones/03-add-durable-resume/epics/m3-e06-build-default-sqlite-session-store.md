---
epic: M3-E06
type: epic
title: Build the Default SQLite Session Store
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e06
depends_on: [M3-E02, M3-E03, M3-E05]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E06: Build the Default SQLite Session Store

## Goal

Implement the versioned local SQLite repository for Console records and authoritative Jidoka session values.

## Scope

- Create the store metadata, session head, immutable record, snapshot, Jidoka session, watermark, migration, backup, archive, and administrative tables.
- Implement the storage behavior and deterministic query bounds.
- Implement a `Jidoka.Session.Store` adapter that runs public Jidoka transitions inside SQLite transactions.
- Keep Console JSON records and opaque Jidoka values in separate logical tables.
- Enforce unique event, sequence, receipt, idempotency, generation, revision, and record identities.
- Implement session discovery, bounded range reads, receipt lookup, and integrity inspection.
- Apply the 1 GiB database, 864 MiB normal page ceiling, 160 MiB control-page reserve, per-session, record, event, 128 MiB Jidoka-value, and reader limits.
- Reject sensitive Console and opaque Jidoka data before encoding or transaction start.

## Out of Scope

- The supervised writer and home lock
- Session generation claim policy
- Live session integration
- Recovery coordinator
- Backup, archive, or repair workflows
- Cross-file state-tree quota and maintenance policy

## Dependencies

This epic depends on M3-E02, M3-E03, M3-E05. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E02 qualifies the exact adapter and SQLite settings.
- M3-E03 supplies record codecs, migrations, and conformance tests.
- M3-E05 supplies the pinned Jidoka custom-store boundary.

### Decisions and invariants

- Use one SQLite database under the versioned Jido state root.
- One Jidoka row is authoritative for its Jidoka session. Console records store only Jidoka link identities and digests.
- All mutations take an operation ID and support exact lookup after a timeout.
- Bound every query by item count and encoded bytes. Do not load every session or event by default.
- Set and verify the frozen pragmas on every open. A setting mismatch fails startup.
- The Jidoka value path has one explicit 136 MiB request envelope. It cannot enter the small-request lane or an unbounded mailbox.
- Normal reads use at most 12 reader connections, an 8 MiB page cache each, and finish their transaction within 1 second. Four readers stay reserved for recovery and administration. The writer cache is 32 MiB and all SQLite store connections share a 512 MiB library heap cap.

### Delivery steps

1. Create the schema and migration-zero bootstrap.
2. Implement canonical Console record append and bounded range queries.
3. Implement session heads, idempotency lookup, generation conditions, and derived snapshot rows.
4. Implement the public Jidoka store adapter and bounded opaque value codec.
5. Add pre-encode structural credential-bearing validation on both logical record families.
6. Implement store inspection, page accounting, reader interruption, and intrinsic limit checks.
7. Run the Console storage and Jidoka custom-store conformance suites.
8. Add corruption, duplicate, ordering, future-schema, sensitive-value, reader-age, and capacity fixtures.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Console append | Receipt and event constraints commit atomically | Duplicate ID returns existing or typed conflict |
| Jidoka transition | Public transition commits one new authoritative value | Stale lease or revision changes nothing |
| Range read | Ordered values within count and byte bounds | No unbounded list |
| Capacity | Record, session, and database limits stop before commit | Maintenance reserve remains |
| Large Jidoka value | One bounded large path commits or fails before mutation | 128 MiB value; 136 MiB envelope |
| Reader | A bounded query closes before its age limit | 16 connections; 4 reserved; 1 second |
| Credential-bearing data | Console and Jidoka credential-value fields and supported structures fail before encode | Zero new database or WAL bytes |
| Integrity | Schema, metadata, row digests, and heads verify | Corruption names the affected scope |

### Completion boundary and handoff

M3-E07 gives this repository one supervised owner and safe home lifecycle. No later epic can open a second writable connection.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- The store creates only the declared versioned SQLite files.
- Console records use canonical JSON and Jidoka values remain in their separate authoritative table.
- All identity, order, idempotency, revision, and generation constraints are enforced in transactions.
- The Jidoka adapter passes the M3-E04 custom-store suite.
- Queries and values stay within declared count and byte limits.
- Normal database admission stops at 864 MiB and leaves 160 MiB for declared control work.
- The large Jidoka path and reader pool stay within their declared count, byte, and age limits.
- Capacity or structural credential-bearing failure occurs before a durable
  acknowledgement candidate exists. Declared final-call credential canaries
  remain the containment responsibility of M3-E15.
- Integrity and incompatible-schema failures are explicit and do not create an empty store.
- No session process or client uses the store directly.

## Proof Artifacts

- SQLite schema and migration-zero record
- Storage behavior conformance result
- Jidoka SQLite adapter result
- Constraint and idempotency fixtures
- Bounded query measurements
- Capacity and integrity results
- Large-value, reader-age, and sensitive-value results

## Milestone Traceability

This epic implements the file-only indexed state foundation for both Console truth and Jidoka execution truth.
