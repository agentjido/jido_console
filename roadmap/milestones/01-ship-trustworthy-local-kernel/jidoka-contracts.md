# Milestone 1 Jidoka contract link

Beadwork: `jido_console-m1e04`

The restricted v0.1 policy and execution-adapter contracts land in Jidoka, not
in Jido Console.

| Field | Value |
| --- | --- |
| External pull request | https://github.com/agentjido/jidoka/pull/55 |
| Branch | `feat/m1-e04-restricted-contracts` |
| Immutable source on current Jidoka main | `974608babab358c0a4b7bd8d065069476186c795` |
| Immutable source on the Console pin | `419bb36b428c8ef3e0a06455d4e90ba409573f59` |
| Release target | v0.1 |
| Owner | Milestone 1 / jido_console-m1e04 |
| Console integration | M1-E05 |

The pull request adds `consent_required` and `unsupported` policy outcomes and
`Jidoka.ExecutionEnvironment.RestrictedContract` for explicit roots,
environment allowlists, credential references, network policy, resources,
cancellation, deadlines, and cleanup evidence.

Update the SHA above if the Jidoka pull request is rebased before merge.
