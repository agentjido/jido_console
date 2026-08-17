# M2-E32 deletion inventory

M2-E27 made these items unreachable from the production TUI. M2-E32 owns
their deletion after parity proof:

- `Jido.Console.Tui.EventProjection` and its raw Jidoka event tests.
- Raw-result compatibility clauses in `Jido.Console.Tui.State`.
- Legacy `Session.Server` attach mode, snapshot push, acknowledgement, and
  recovery facade functions.
- Legacy server tests that attach without the bounded client facade.
- The temporary TUI path in `Session.Client.Boundary.legacy_allowlist/0`.

The production `Jido.Console.Tui` loop has no call or receive path to these
items after M2-E27.
