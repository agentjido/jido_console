# Old TUI Session Path Removal

This report records the M2-E32 deletion proof.

## Before-deletion inventory

M2-E27 recorded these isolated items:

- `Jido.Console.Tui.EventProjection` and its raw Jidoka tests.
- Raw result clauses in `Jido.Console.Tui.State`.
- The legacy `Session.Server` attach mode and snapshot push.
- The legacy acknowledgement and recovery facades.
- The temporary client-boundary allowlist.
- No-op raw runtime broadcast calls and helpers.

The production TUI had no call or receive route to these items. The M2-E31
proof passed before deletion with ledger fingerprint
`sha256:075e0de8df90d5e56790a2b70e0a09099f142d07a2f3a6cd367cb9803f1252d8`.

## Deleted source

The deletion removed the raw event projector, raw-only TUI state clauses,
legacy delivery modes, snapshot pushes, sequence acknowledgements, recovery
wrappers, raw runtime broadcasts, compatibility options, and raw-only tests.
The server attach operation now always returns an exact bounded attachment and
snapshot. It has no compatibility switch.

## Source boundary

`Jido.Console.Session.Client.Boundary` parses Elixir syntax. It rejects:

- Direct session-owner, delivery, recovery, or raw Jidoka module access from a
  production client.
- Raw runtime and old session message patterns.
- Legacy attach options and facade functions.
- Runtime broadcast helpers and the deleted raw projector.

The deliberate fixture at
`test/fixtures/session/legacy_tui_client_path.fixture` has each representative old
pattern. The guard rejects the fixture. Comments and documentation do not
affect the result.

## Approved ingress

The exact production raw-event receiver list has one entry:

| Path | Function | Purpose |
| --- | --- | --- |
| `lib/jido_console/session/server.ex` | `handle_info/2` | Owner-only `{:jidoka_turn_event, event}` ingress |

Provider-free runtimes can send this owner message. No TUI module receives or
projects it.

## After-deletion report

The following production searches returned zero unapproved matches:

- Raw projector names, raw Jidoka tuples, and runtime result structs in the TUI
  and its client adapter.
- Runtime broadcast helpers and message tags in the session owner.
- Legacy attach mode, return switch, acknowledgement, and recovery helpers.
- Snapshot-push messages and selectable compatibility paths.

The syntax guard also returned zero violations for all TUI modules and the
session owner, delivery, recovery, and local-driver paths.

## Behavior proof

- Unchanged M2-E31 parity proof: 8 tests passed.
- TUI, terminal, detach, recovery, and owner suite: 148 tests passed; the
  compiled PTY test was excluded from this run.
- Compiled executable and real PTY: 1 test passed; 1 non-PTY test was excluded.
- Normalized parity ledger and visible side effects did not change.

The production TUI now owns only renderer state and renderer effect workers.
All semantic session output comes from bounded `Session.Client` batches.
