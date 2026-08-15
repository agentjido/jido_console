# Milestone 2 Jidoka portable projection

Beadwork: `jido_console-m2e05`

The portable request-stream projection lands in Jidoka, not in Jido Console.

| Field | Value |
| --- | --- |
| External pull request | https://github.com/agentjido/jidoka/pull/58 |
| Branch | `feat/m2-e05-portable-projection` |
| Immutable source | `6e63a992f5f81bcd8f667ebcc36ac051a2431c5b` |
| Root facade | `Jidoka.project_events/1` |
| Depends on | https://github.com/agentjido/jidoka/pull/56, https://github.com/agentjido/jidoka/pull/57 |
| Release target | v0.2 |
| Owner | Milestone 2 / jido_console-m2e05 |
| Console integration | M2-E06 |

`Jidoka.project_events/1` returns JSON-compatible maps with request, turn, and
event identities. Sensitive values are redacted. Size and unknown-data bounds
are enforced. PIDs, references, functions, and private runtime structs do not
cross the facade.

Update the SHA above if the Jidoka pull request is rebased before merge.
