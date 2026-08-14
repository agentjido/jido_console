# Roadmap Item Ownership

Roadmap ownership keeps work small and prevents long reservations.

## Claim an Item

1. Select a roadmap item that a maintainer has marked ready.
2. Confirm that the item has no active owner or open pull request.
3. Comment `I own this for the next 12 hours` on its tracking issue.

The issue comment time starts the 12-hour period. Own only one item at a time.

## Finish in 12 Hours

Open a non-draft pull request that is ready for review within 12 hours. The pull
request must link to the item and satisfy its stated acceptance checks.

Review and merge can occur after the 12-hour period. A draft pull request does
not finish the item.

## Expired Ownership

Ownership expires automatically after 12 hours if there is no pull request that
is ready for review. Another contributor can then claim the item. No maintainer
action is necessary.

If you cannot finish, comment that you release the item. You can claim it again
if it is still available.

Ownership reserves implementation time. It does not change the roadmap or give
approval to increase the scope. Use a discussion for design or scope changes.
