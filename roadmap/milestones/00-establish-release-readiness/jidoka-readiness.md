# Jidoka release readiness

Status: Milestone 1 uses an immutable Git pin that includes the additive
restricted v0.1 contracts.

Jido Console is pinned to Jidoka commit
`419bb36b428c8ef3e0a06455d4e90ba409573f59`. That commit is the previous
immutable pin plus the additive policy and restricted-execution contracts from
[Jidoka pull request 55](https://github.com/agentjido/jidoka/pull/55). It is
not a Hex package and it is not the planned Jidoka v0.9.1 release.

Known compatibility limits: Console uses only public Jidoka client, policy,
and execution-environment facades. Restricted-path enforcement beyond those
contracts remains Console work in later Milestone 1 epics.

## Blocker order

| Order | Work | Owner | Target | Proof |
| --- | --- | --- | --- | --- |
| 1 | [#51 deterministic async event order](https://github.com/agentjido/jidoka/issues/51) | Jidoka maintainers | v0.9.1 | Jidoka event-order tests |
| 2 | [#50 request-controller cleanup](https://github.com/agentjido/jidoka/issues/50) | Jidoka maintainers | v0.9.1 | Jidoka lifecycle tests |
| 2 | [#52 safe policy defaults](https://github.com/agentjido/jidoka/issues/52) | Jidoka maintainers | v0.9.1 | Jidoka policy tests |
| 3 | [#53 unsafe-effect recovery](https://github.com/agentjido/jidoka/issues/53) | Jidoka maintainers | v0.9.1 | Jidoka recovery tests |
| 4 | [#54 public execution-adapter contracts](https://github.com/agentjido/jidoka/issues/54) | Jidoka maintainers | v0.9.1 | Public API contract tests |

The issue state is planning data. It does not prove that a release contains the work.

## Compatibility rule

Milestone 1 can replace the current pin only after Jidoka publishes an immutable version that contains the five changes. Jido Console must pin that exact version or commit and pass these existing checks:

- `test/jido_console/jidoka_dependency_test.exs`
- `test/jido_console/jidoka_public_api_boundary_test.exs`
- `test/jido_console/release/cross_repo_test.exs`

A local path, a branch name, an unverified tag, or an issue state is not an approved production dependency. Beadwork item `jido_console-g0e10` owns changes to this decision.
