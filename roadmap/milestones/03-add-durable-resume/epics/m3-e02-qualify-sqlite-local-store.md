---
epic: M3-E02
type: epic
title: Qualify SQLite for the Local Store
status: skipped
milestone: milestone-3
beadwork_id: jido_console-m3e02
depends_on: [M3-E01]
release: v0.3
delivery_unit: none
introduced_in: 1.3.0
last_updated_in: 1.3.5
---

# M3-E02: Qualify SQLite for the Local Store

## Status

Skipped by roadmap decision in version 1.3.5. This epic has no implementation
pull request and does not block M3-E06.

## Reason

The separate qualification gate found that the selected maintained adapter
does not expose the SQLite online backup C API. That API is not required to
create, commit, reopen, or read the live session store.

SQLite remains the selected engine. The frozen file, transaction, privacy,
capacity, and integrity rules remain in force.

## Handoff

- M3-E06 declares the direct adapter and proves its minimum package, pragma,
  commit, reopen, crash, path, and integrity behavior with the production
  store.
- M3-E17 creates a consistent snapshot with SQLite `VACUUM INTO`, under the
  writer barrier, and verifies the result before adoption.
- M3-E34 owns the complete production crash matrix.

## Completion Record

Beadwork closes `jido_console-m3e02` with reason `skipped`. M3-E02 does not
block M3-E06 or any later epic.
