# v0.2 release audit

Beadwork: `jido_console-m2e34`

This is an evidence-only record for the source candidate on
`feat/m2-supervised-session-plane`.

| Field | Value |
| --- | --- |
| Decision | source candidate ready; publication blocked until the protected workflow runs |
| Jidoka ordered events | https://github.com/agentjido/jidoka/pull/56 |
| Jidoka controller cleanup | https://github.com/agentjido/jidoka/pull/57 |
| Jidoka portable projection | https://github.com/agentjido/jidoka/pull/58 |
| Jidoka session-chat terminal | https://github.com/agentjido/jidoka/pull/59 |
| Jidoka pin | `701cf25a5c922755f4c53f25eb9721f1c85adf0a` |
| Known limit | Accepted input can be lost on an application crash before Milestone 3 |
| Unresolved | Native payload checksums, Homebrew/npm publication, and signed archive acceptance wait for the protected release workflow |

This audit does not publish v0.2 and does not change the candidate payload.
