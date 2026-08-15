# Milestone 2 Jidoka request-controller cleanup

Beadwork: `jido_console-m2e02`

Request-controller cleanup and handle semantics land in Jidoka, not in Jido
Console.

| Field | Value |
| --- | --- |
| External pull request | https://github.com/agentjido/jidoka/pull/57 |
| Branch | `feat/m2-e02-request-controller-cleanup` |
| Immutable source | `960ac477` |
| Depends on | https://github.com/agentjido/jidoka/pull/56 |
| Release target | v0.2 |
| Owner | Milestone 2 / jido_console-m2e02 |
| Console integration | M2-E06 |

Chat and session-sequence controllers stop after a bounded retention window.
Completion, error, cancellation, timeout, and owner exit leave no live
controller. Completed handles return the same result and do not restart work.
Expired handles return `:request_expired`. A cleanup race cannot create a
second terminal event or a second live controller.

Update the SHA above if the Jidoka pull request is rebased before merge.
