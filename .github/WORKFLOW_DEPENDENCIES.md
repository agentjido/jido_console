# Workflow dependencies

The CI and review jobs use reusable workflows from `agentjido/github-actions`. Each `uses` value has a full commit SHA. The comment records the related release tag for maintainers.

| Workflow | Release | Commit |
| --- | --- | --- |
| Jido CI | v5 | `c782c2d13584f0a7b43027eedd83807ed1a2b7dc` |
| Jido Review | v4 | `de26f5eb164c54dc1f39182d2303ca1a36a7d8d0` |

To update a dependency:

1. Review the upstream changes and resolve the new tag to a full commit SHA.
2. Replace the SHA and its tag comment in one pull request.
3. Keep explicit workflow permissions. Do not use `secrets: inherit`.
4. Pass the CI and review jobs before merge.

These workflows run the normal repository checks. Release-readiness audits and their local results do not run in GitHub Actions. This repository has no publish job.
