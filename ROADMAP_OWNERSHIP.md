# Roadmap Work Ownership

Each directory in [`roadmap/milestones/`](roadmap/milestones/README.md) contains one release milestone. A milestone can produce several epics, implementation issues, and pull requests. Do not reserve an entire milestone or epic for 12 hours.

## Claim Scoped Work

1. Select a scoped implementation issue that belongs to a ready milestone or generated epic.
2. Confirm that the issue has no active owner or open pull request.
3. Comment `I own this for the next 12 hours` on the issue.

The issue comment time starts the 12-hour period. Own only one scoped issue at a time.

## Finish in 12 Hours

Open a non-draft pull request that is ready for review within 12 hours. The pull request must link to the issue, generated epic, and roadmap milestone. It must satisfy the issue acceptance checks.

Review and merge can occur after the 12-hour period. A draft pull request does not finish the issue.

## Expired Ownership

Ownership expires automatically after 12 hours if there is no pull request that is ready for review. Another contributor can then claim the issue. No maintainer action is necessary.

If you cannot finish, comment that you release the issue. You can claim it again if it is still available.

Ownership reserves implementation time. It does not change a milestone, epic, release gate, or product scope. Use a discussion for design or scope changes.
