# Milestone 1 Jidoka contract link

Beadwork: `jido_console-m1e04`

The restricted v0.1 policy and execution-adapter contracts land in Jidoka, not
in Jido Console.

| Field | Value |
| --- | --- |
| External pull request | https://github.com/agentjido/jidoka/pull/55 |
| Branch | `feat/m1-e04-restricted-contracts` |
| Immutable source on current Jidoka main | `7a346949aeb5c829ee0fad7b6b38eb23839b1384` |
| Immutable source on the Console pin | `7a346949aeb5c829ee0fad7b6b38eb23839b1384` |
| Release target | v0.1 |
| Owner | Milestone 1 / jido_console-m1e04 |
| Console integration | M1-E05 |

The pull request adds `consent_required` and `unsupported` policy outcomes and
`Jidoka.ExecutionEnvironment.RestrictedContract` for explicit roots,
environment allowlists, credential references, network policy, resources,
cancellation, deadlines, and cleanup evidence.

Update the SHA above if the Jidoka pull request is rebased before merge.
