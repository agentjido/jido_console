---
epic: M2-E40
type: epic
title: Preserve the Native Root in the npm Launcher
status: proposed
milestone: milestone-2
beadwork_id: jido_console-ih5
depends_on: [M2-E39]
release: v0.2
delivery_unit: one_pull_request
introduced_in: 1.3.4
last_updated_in: 1.3.4
---

# M2-E40: Preserve the Native Root in the npm Launcher

## Goal

Make the npm entry command run the native launcher from the target package so
the launcher can find its adjacent private runtime.

## Scope

- Keep the native archive contents below the npm target package.
- Write a small entry-package launcher that resolves npm command links.
- Run the native launcher in place inside the target package.
- Replace the simulated npm command with a link to the entry launcher.
- Preserve global, local, exec, and npx lifecycle behavior.
- Prove the real candidate payload through the three-channel matrix.

## Out of Scope

- A new npm package, platform, architecture, or install script
- npm publication
- A native launcher contract change
- Candidate qualification or release audit

## Dependencies

This epic depends on M2-E39 because the failed channel run used the repaired
paint-first candidate source. It blocks M2-E36 because npm is a declared
macOS ARM64 channel and must complete its full lifecycle.

## Pull Request Boundary

Deliver this epic in exactly one packaging repair pull request. It changes the
npm entry launcher, tests, roadmap graph, and repair proof. It does not qualify
or publish a candidate.

## Acceptance Checks

- The npm entry launcher is a regular executable in the entry package.
- The exposed npm command is a link to the entry launcher.
- The entry launcher resolves that link and runs the native launcher in the
  target package.
- The native launcher still finds its adjacent `libexec` private runtime.
- npm global, local, exec, and npx flows pass install, first run, update, and
  removal without compilation or install scripts.
- The same real payload checksum passes archive, Homebrew, and npm lifecycles.
- Focused tests, the complete suite, and the common precommit gate pass.

## Proof Artifacts

- `roadmap/milestones/02-ship-supervised-session-plane/proof/npm-native-root.md`
- Focused channel and matrix test results
- Real-payload channel matrix result

## Milestone Traceability

This epic repairs one declared delivery channel. It does not change the native
payload, support matrix, or Milestone 2 session-plane claim.
