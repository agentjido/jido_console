---
epic: M3-E03
type: epic
title: Define Durable Records, Codecs, and Migrations
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e03
depends_on: [M3-E01]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E03: Define Durable Records, Codecs, and Migrations

## Goal

Define strict, versioned durable Console records and deterministic migrations without adding storage I/O.

## Scope

- Define schemas for store metadata, sessions, generations, records, receipts, queues, interactions, permissions, turn manifests, effects, watermarks, forks, and administrative decisions.
- Define canonical JSON encoding, stable digests, prior-record links, and byte accounting for Console records.
- Define a bounded opaque Jidoka-store value envelope with Jidoka revision, schema, digest, and encoded size.
- Define strict, versioned credential-profile and credential-reference metadata without a credential-value field.
- Define migration identifiers, checksums, preconditions, transformation results, and compatibility rules.
- Reject credential-value fields, credential-bearing structures, inline
  authorization data, process values, renderer state, raw provider clients, and
  unbounded unknown data before encoding. Do not resolve an external credential
  source during codec validation.
- Add a reusable codec and migration conformance suite.

## Out of Scope

- SQLite table creation
- Home paths or file permissions
- Jidoka runtime behavior changes
- Storage writer process
- Recovery orchestration

## Dependencies

This epic depends on M3-E01. These dependencies supply the approved contracts and implementation boundaries required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only the goal and scope above. It must not absorb a downstream implementation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E01 provides the complete record inventory, identities, bounds, and acknowledgement rules.
- The M2 canonical protocol codec and validation patterns are frozen.

### Decisions and invariants

- Console records use canonical JSON. Hash input is the exact canonical encoded byte sequence.
- Jidoka values are opaque to Console semantics. Their envelope is bounded and checksummed, and decode must finish with public Jidoka schema validation.
- Schema versions and store-format versions are separate. A protocol change does not silently migrate storage.
- Migrations are ordered, deterministic, idempotent, and checksum-identified. A future schema fails before mutation.
- Digest chains detect accidental mutation and corruption. They are not an authentication claim against the current operating-system user.
- Credential profiles use typed source metadata. They do not use free-form secret URIs, query data, interpolation, shell commands, or generic file-value reads.
- The opaque Jidoka envelope has the same pre-encode structural
  credential-bearing gate as Console records and a 128 MiB encoded-value limit.

### Delivery steps

1. Add record envelope, type, and identity modules.
2. Add canonical JSON encoding and digest-chain functions.
3. Add the opaque Jidoka value envelope and safe decode boundary.
4. Add credential-profile and reference metadata schemas with no value, fingerprint, prefix, suffix, or length field.
5. Add migration behavior, ledger value, and compatibility result types.
6. Add recursive forbidden-runtime-value, credential-bearing-structure, and reference-metadata validation without external source resolution.
7. Add round-trip, canonical-byte, migration, future-version, tamper, secret, and oversize fixtures.
8. Publish the storage-schema and compatibility matrices.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Round trip | Each authoritative record decodes to the same normalized value | Canonical bytes and digest are stable |
| Migration | Each supported source reaches one target result | Second run makes no change |
| Future schema | Decode returns typed incompatible result | No replacement value |
| Forbidden data | Live BEAM values, credential-value fields, and supported credential-bearing structures fail | No durable acknowledgement candidate |
| Credential metadata | Only declared source identity and reference metadata pass | No value-bearing or free-form locator field |
| Jidoka value | Credential-bearing structures or oversized opaque data fail before encode | 128 MiB maximum and zero written bytes |
| Tamper | Insertion, deletion, reordering, and mutation fail chain validation | Exact failing record identified |

### Completion boundary and handoff

M3-E06 implements these schemas in SQLite. Later epics add record families only through an approved additive schema or migration.

### Risks and controls

- A dependency can expose an incomplete contract. Stop and return the defect to its owning epic.
- A convenience path can bypass the declared owner. Add structural and runtime boundary checks.
- A test can prove only in-memory behavior. Tie every durability claim to its declared commit or file boundary.

## Acceptance Checks

- Every authoritative Console record has one current schema and a bounded encoded form.
- Equivalent normalized input produces identical canonical bytes and digests.
- All supported schema revisions migrate deterministically and idempotently.
- A future or unknown version returns a typed incompatible result.
- Jidoka values remain logically separate from Console JSON records and validate through the public Jidoka contract after decode.
- Credential-value fields, supported credential-bearing structures, and live
  BEAM values fail before encoding. Arbitrary string values are not compared
  with an external credential source in this epic.
- Credential-profile records cannot contain a value, value fingerprint, inline authorization data, shell text, or unknown source metadata.
- Tamper and corruption fixtures identify the exact invalid record.
- No file or database operation is part of this epic.

## Proof Artifacts

- Durable schema catalog
- Canonical codec fixtures
- Opaque Jidoka envelope contract
- Migration ledger and compatibility matrix
- Forbidden-value corpus
- Digest-chain tamper results

## Milestone Traceability

This epic supplies the durable data and migration contract for the Console store while preserving Jidoka as the execution-truth owner.
