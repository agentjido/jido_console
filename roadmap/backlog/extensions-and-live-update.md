# Extensions and Live Update Backlog

## EXT-001: Bind extension consent to content

- Phase: 10
- Priority: high
- Work: Bind review and approval to exact paths, content, capabilities, and artifact digest.
- Acceptance: A file add, edit, or removal requires a new decision.

## EXT-002: Make live mutations reconstructible

- Phase: 10
- Priority: high
- Work: Store source identity, build and test results, replay artifact, selection, and rollback target for each live mutation.
- Acceptance: A clean process can reconstruct and verify the selected change.

## EXT-003: Keep recovery outside mutable code

- Phase: 10
- Priority: high
- Work: Provide a stable launcher and recovery path that do not load the damaged active extension or runtime.
- Acceptance: Recovery can select a compatible retained version or clean exact-source build.

## EXT-004: Authenticate process handoff

- Phase: 10
- Priority: medium
- Work: Drain normal work, write private handoff state, transfer an owner lease, and require an authenticated readiness claim.
- Acceptance: The old owner stops only after the new owner holds the valid lease. Startup failure keeps the old owner active.

## EXT-005: Promote restricted tools to trusted extensions

- Phase: 10
- Priority: high
- Work: Review the evidence from a restricted executor and record the decision for the exact artifact and capabilities.
- Acceptance: Promotion is explicit, auditable, revocable, and repeatable.

## EXT-006: Enforce per-hook failure policy

- Phase: 10
- Priority: high
- Work: Run extensions in bounded processes and apply the declared open, closed, or stop-session failure rule.
- Acceptance: A failed policy hook cannot permit an effect. A failed information hook is visible.
