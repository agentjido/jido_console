---
epic: M3-E13
type: epic
title: Add Secret-Free Credential Profiles
status: proposed
milestone: milestone-3
beadwork_id: null
beadwork_import_id: jido_console-m3e13
depends_on: [M3-E03, M3-E08]
release: v0.3
delivery_unit: one_pull_request
introduced_in: 1.3.0
last_updated_in: 1.3.0
---

# M3-E13: Add Secret-Free Credential Profiles

## Goal

Persist stable credential-source identity for exact resume without persisting, copying, or managing a credential value.

## Scope

- Store versioned, immutable credential profiles and reference metadata in the bounded SQLite store under `JIDO_HOME`.
- Support declared references to a host environment variable, one private user-owned dotenv variable, and one existing read-only operating-system keychain item.
- Use strict typed source records. Do not accept a free-form secret URI or a generic file-value source.
- Resolve the exact reference selected for the durable turn only at the final provider or tool boundary.
- Add redacted profile list, show, status, compatibility, disable, and missing-source results.
- Reject credential values and value-bearing fields before a profile or durable operation can be written.
- Keep every Jido-owned durable credential-profile and storage byte under
  `JIDO_HOME`; treat external secret sources as read-only runtime inputs, not
  resume state.

## Out of Scope

- Creating, changing, importing, exporting, backing up, restoring, archiving, or deleting a secret value
- Keychain writes
- A vault, cloud secret service, or remote credential broker
- Generic `file:` secret reads
- Passing a secret in a CLI argument, protocol value, agent, scenario, suite, prompt field, or durable command
- Model or tool execution

## Dependencies

This epic depends on M3-E03 and M3-E08. These dependencies supply the versioned secret-free record contract and the only bounded durable write path required by this pull request.

## Pull Request Boundary

Deliver this epic in exactly one pull request. The pull request delivers only profile metadata, read-only resolvers, redacted status, and final-boundary materialization. It must not add turn persistence, model or tool work, a secret-store mutation, client migration, proof, candidate, audit, or publication task.

## Detailed Delivery Plan

### Preconditions

- M3-E03 rejects value-bearing and unknown credential metadata.
- M3-E08 can reserve and account for every profile write.
- Existing provider and coding contracts can name declared credential variables.

### Decisions and invariants

- A profile grants no authority. It identifies an ordered set of read-only sources.
- A durable turn records the selected reference identity. Resume resolves that same reference and does not silently select a different fallback.
- A value rotation at the same immutable reference is allowed. Jido never
  compares the value across calls and never persists the value, its digest,
  prefix, suffix, or length. The final provider or tool call can compare the
  already-materialized value with that call's arguments or result only for
  process-local containment, then discards it.
- Attach, restore, transcript replay, status, and audit do not resolve secrets.
- Dotenv input must be a bounded private regular file. Reject links, path traversal, unsafe mode, unknown fields, interpolation, and shell text.
- A keychain adapter is injected, platform-qualified, read only, and called only at the final boundary.
- Profile admission uses structural metadata rules only. It does not resolve a
  source to compare an ordinary input value.

### Delivery steps

1. Add versioned profile, profile version, reference, and redacted-status values.
2. Add immutable profile create and new-version operations with bounded source metadata.
3. Add host-environment, private-dotenv, and read-only keychain resolver adapters.
4. Add exact-reference selection and final-boundary materialization.
5. Add redacted list, show, status, disable, missing, denied, and unavailable results.
6. Add recursive rejection for value fields, URI user data, query credentials, interpolation, shell text, inline authorization, and unknown fields.
7. Add isolated-home, restart, rotation, missing-source, permissions, platform, redaction, and secret-canary tests.

### Test and evidence matrix

| Case | Required oracle | Required bound or identity |
| --- | --- | --- |
| Profile restart | Same immutable profile and reference IDs load | No credential value or fingerprint |
| Exact resume source | The recorded reference is resolved | No fallback reselection |
| Rotated value | Same reference can resolve a new value | No cross-call comparison or storage; in-call containment only |
| Dotenv | Only a named variable in a private regular file is read | No link, traversal, write, or copy |
| Keychain | One declared item is read through the injected adapter | Zero keychain mutation |
| Redaction | All product and evidence surfaces contain IDs and status only | Zero canary value |

### Completion boundary and handoff

M3-E14 stores only profile, version, and selected-reference identities in a turn manifest. M3-E15 checks the recorded reference immediately before effect dispatch. No later epic can add a credential-value field.

### Risks and controls

- A status result can expose locator data. Use a separate portable redacted view.
- A fallback chain can change authority after restart. Bind each turn to the selected immutable reference.
- A resolver can broaden process exposure. Materialize only at the final boundary and clear process-local data after use.

## Acceptance Checks

- Every Jido-owned durable profile byte stays below `JIDO_HOME/state/`.
- Profile and reference records contain no secret value, fingerprint, prefix, suffix, or length.
- Product data-entry surfaces accept a profile ID, not a credential value.
- Environment, dotenv, and keychain sources are read only and resolve only at the final provider or tool boundary.
- Resume uses the exact recorded reference and does not select a new fallback silently.
- Missing, changed, denied, disabled, or unavailable source identity returns a typed stop before provider or tool work.
- Profile list, show, status, logs, events, protocol values, backups, archives, and audit output remain redacted.
- No keychain, dotenv, vault, cloud, or remote secret value is created, changed, copied, backed up, restored, archived, exported, or deleted.

## Proof Artifacts

- Credential-profile and reference schemas
- Resolver registry and source matrix
- Final-boundary materialization trace
- Private-dotenv and keychain qualification results
- Restart, rotation, and exact-reference fixtures
- Complete credential-canary scan

## Milestone Traceability

This epic preserves the original operating-system secret-profile goal while keeping all Jido-owned durable state file based and below `JIDO_HOME`.
