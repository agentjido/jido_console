# Milestone 2 Proof Index

This index separates historical evidence from the final Milestone 2 closeout
evidence. It does not change an existing proof record.

## Final Closeout Evidence

| Epic | Planned record | Purpose |
| --- | --- | --- |
| M2-E38 | `release-acceptance-home.md` | Prove the clean installed-artifact environment uses one private product home. |
| M2-E36 | `v0-2-closeout-candidate.md` | Prove one exact post-closeout source and production artifact. |
| M2-E37 | `v0-2-closeout-audit.md` | Audit that source and artifact, reaffirm skipped publication, and name the Milestone 3 baseline. |

These records do not exist until their owning epics complete. M2-E37 is the
final Milestone 2 gate. It does not authorize publication.

## Historical Evidence

| Epic | Record | Status in roadmap 1.2.0 |
| --- | --- | --- |
| M2-E33 | [`v0-2-candidate.md`](v0-2-candidate.md) | Historical candidate for the pre-closeout source |
| M2-E34 | [`v0-2-audit.md`](v0-2-audit.md) | Historical audit for the pre-closeout source |
| M2-E35 | [`v0-2-publish.md`](v0-2-publish.md) | Historical publication-state record |

The historical records remain unchanged. They do not qualify the source after
M2-E09, M2-E17, M2-E18, M2-E26, M2-E27, M2-E31, and M2-E32 complete.

The text in `v0-2-publish.md` describes the policy state when M2-E35 closed.
The current policy supersedes it: publication is intentionally skipped. Do not
run a release workflow, create a tag, or publish a package for v0.2.
