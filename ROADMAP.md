# Jido Console Roadmap Guide

The target product architecture is in
[`JIDO_CONSOLE_PLAN.md`](JIDO_CONSOLE_PLAN.md). This roadmap owns delivery
order, milestone scope, and release gates.

The canonical roadmap is in [`roadmap/README.md`](roadmap/README.md).

- Milestone definitions: [`roadmap/milestones/`](roadmap/milestones/README.md)
- Roadmap history: [`roadmap/CHANGELOG.md`](roadmap/CHANGELOG.md)

Each milestone directory contains one `milestone.md`. An approved milestone can
generate several epics. Each generated epic is delivered in one pull request.
Generated epics belong in an `epics/` directory under the owning milestone.
Beadwork owns implementation tasks, task dependencies, and delivery state.

## Change the Roadmap

Use a discussion for a product, scope, milestone, dependency, release-gate, or
architecture change. Update the canonical roadmap and its changelog in one
logical commit. Do not use an implementation pull request to change the owning
milestone without an explicit roadmap decision.

## Own Scoped Work

A milestone can require several epics and issues. Each generated epic has one
scoped issue and one pull request. Do not reserve an entire milestone for 12
hours.

1. Select a scoped implementation issue for a ready milestone or generated
   epic.
2. Confirm that the issue has no active owner or open pull request.
3. Comment `I own this for the next 12 hours` on the issue.
4. Open a non-draft pull request that is ready for review within 12 hours.
5. Link the pull request to the issue, generated epic when present, and roadmap
   milestone.
6. Satisfy the issue acceptance checks and the applicable milestone gate.

Own only one scoped issue at a time. The issue comment time starts the 12-hour
period.

Ownership expires after 12 hours if no pull request is ready for review.
Another contributor can then claim the issue. Review and merge can occur after
the ownership period.

Release the issue in a comment if you cannot finish. Ownership reserves
implementation time. It does not change a milestone, epic, release gate, or
product scope.
