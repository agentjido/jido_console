# Jidoka release readiness

Status: The blocker issues are closed. Dependency replacement is not ready.

Jido Console is pinned to Jidoka commit `f19ce72e7591b3215e832e6e034e3752e84a3604`. This is an immutable source, but it is not the planned Jidoka v0.9.1 release.

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

- `test/jido_cli/jidoka_dependency_test.exs`
- `test/jido_cli/jidoka_public_api_boundary_test.exs`
- `test/jido_cli/release/cross_repo_test.exs`

A local path, a branch name, an unverified tag, or an issue state is not an approved production dependency. Beadwork item `jido_console-g0e10` owns changes to this decision.
