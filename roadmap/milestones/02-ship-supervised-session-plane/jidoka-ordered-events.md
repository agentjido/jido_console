# Milestone 2 Jidoka ordered-event contract

Beadwork: `jido_console-m2e01`

The ordered async event contract lands in Jidoka, not in Jido Console.

| Field | Value |
| --- | --- |
| External pull request | https://github.com/agentjido/jidoka/pull/56 |
| Branch | `feat/m2-e01-ordered-async-events` |
| Immutable source | `e05e681d3fd2b4322d7a8f39d5f11aebbafdb857` |
| Release target | v0.2 |
| Owner | Milestone 2 / jido_console-m2e01 |
| Console integration | M2-E06 |

The pull request makes the async request controller the one sequence owner.
Events for one request are classified onto that owner, restamped into a
contiguous sequence, and closed by exactly one terminal event. Completion,
cancellation, timeout, and owner-exit races still produce one terminal result.
A late or foreign event cannot create a second terminal.

Update the SHA above if the Jidoka pull request is rebased before merge.
