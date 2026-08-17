# v0.2 Closeout Audit

Beadwork: `jido_console-m2e37`

Decision: `approved`

This audit approves the exact post-closeout Milestone 2 source and production
candidate as the Milestone 3 baseline. It does not approve publication. The
package version stays `0.1.0`. The approved source-quality target is v0.2.

The audit did not rerun tests or generate new product evidence. It reviewed the
immutable M2-E36 records in evidence commit
`0e0ed85228b592cdde12bc0a46a319406a63813c`.

## Audit Input

| Field | Audited value | Review |
| --- | --- | --- |
| Console source commit | `e7ee26e70c571c9af50ba9840d17f3524ba5e7e0` | Match |
| Console source tree | `7266e79495db8bf6e59277613571a381c9d14f6f` | Match |
| Source state | Clean | Match |
| Roadmap version | `1.3.4` | Match |
| Jidoka commit | `29246d0a762fe1b17f4250e4f5c98c9f3f6d8419` | Match |
| Jidoka tree | `f86eaf57bdea8e347acd5e0aca35c21ebc08850d` | Match |
| Jidoka package version | `0.9.1` | Match |
| Target | `darwin-arm64` | Match |
| Native archive | `jido-0.1.0-darwin-arm64.tar.gz` | Match |
| Native archive size | `78,680,507` bytes | Match |
| Native archive SHA-256 | `65cbb458061e72bd38ac2efe96bef5de6677a9b649d90a12841a8b40303a7e35` | Match |
| Package version | `0.1.0` | Expected source-quality policy |
| Quality target | v0.2 | Expected source-quality policy |
| E36 evidence commit | `0e0ed85228b592cdde12bc0a46a319406a63813c` | Proof-only |
| E36 evidence tree | `265c7bff095854a4a2dc6ba368be11aec0cac9aa` | Proof-only |

The E36 evidence commit changes only
`roadmap/milestones/02-ship-supervised-session-plane/proof/`. It does not change
the candidate. The baseline is the `e7ee26e` source commit, not the E36
evidence commit or this audit commit.

The same source, Jidoka, target, package version, and payload checksum appear in
the provenance, acceptance, channel matrix, and candidate record.

## Stable Evidence Identity

| Evidence | SHA-256 | Review |
| --- | --- | --- |
| [`v0-2-closeout-candidate.md`](v0-2-closeout-candidate.md) | `b92c42a33212ae7016afb7278b40599d276a10ea188dd2c3a287516e0767a802` | Match |
| [`v0-2-closeout-artifact-proof.exs`](v0-2-closeout-artifact-proof.exs) | `88c1923d62b2c2d9167ea715187390fd211a64e6b69ef441d506bed7f6d055ce` | Match |
| [`v0-2-closeout-acceptance.json`](v0-2-closeout-acceptance.json) | `5112bb69c2f6e9a943df24676e69dba629c1a29f359730ebf5a0e53ee1bad73d` | Match |
| [`v0-2-closeout-channel-matrix.json`](v0-2-closeout-channel-matrix.json) | `1cd73fbb33d69afd7bd2036cbb30118f27600a63a6e4e598f3ab8266a3510fbe` | Match |
| [`v0-2-closeout-provenance.json`](v0-2-closeout-provenance.json) | `ba06f997dd8a62be2e6aa139a1956afbf3ea1e50b383d964ba784c8d25e0ae01` | Match |
| [`v0-2-closeout-session-plane.json`](v0-2-closeout-session-plane.json) | `c311a69ea8f90369c7701ffe74f4938232774d9e73abb6db2fc7dd21e580f4e1` | Match |

In the evidence index below, `S/P` means this exact immutable pair:

- Source `e7ee26e70c571c9af50ba9840d17f3524ba5e7e0`.
- Native payload
  `65cbb458061e72bd38ac2efe96bef5de6677a9b649d90a12841a8b40303a7e35`.

Every final-source row uses `S/P`. Earlier source tests remain valid only when
the final clean suite and artifact proof also cover their current code.

## Complete Milestone 2 Evidence Index

| Epic and claim | Evidence and fixture | Source / payload | Platform or channel | Result | Limit or finding |
| --- | --- | --- | --- | --- | --- |
| [M2-E01](../epics/m2-e01-land-ordered-jidoka-async-events.md): one ordered Jidoka async stream | Final Jidoka pin and two-way compatibility gate in the [candidate](v0-2-closeout-candidate.md); Jidoka event contract | `S/P` | Source plus macOS ARM64 artifact | Pass | Final pin replaces the historical PR identity. |
| [M2-E02](../epics/m2-e02-stop-completed-jidoka-request-controllers.md): completed request-controller cleanup | Final Jidoka pin and two-way compatibility gate; request cleanup suite | `S/P` | Source plus macOS ARM64 artifact | Pass | No controller-lifetime defect found. |
| [M2-E03](../epics/m2-e03-define-canonical-session-protocol.md): canonical session protocol | Complete clean suite; `jido.session` protocol version 1 | `S/P` | Source plus all three channels | Pass | Protocol remains process-lifetime in M2. |
| [M2-E04](../epics/m2-e04-generate-protocol-types-and-validators.md): generated types and validators | Complete clean suite; generator and validator tests; protocol version 1 | `S/P` | Source plus all three channels | Pass | Unknown data stays bounded and does not grant authority. |
| [M2-E05](../epics/m2-e05-land-portable-jidoka-projection.md): portable Jidoka projection | Final Jidoka pin and two-way compatibility gate | `S/P` | Source plus macOS ARM64 artifact | Pass | Uses the public pinned facade. |
| [M2-E06](../epics/m2-e06-pin-and-prove-jidoka-integration.md): pinned Jidoka integration | [Provenance](v0-2-closeout-provenance.json) and artifact metadata name Jidoka `29246d0`; cross-repository gate | `S/P` | macOS ARM64, all channels | Pass | Exact pin and package `0.9.1`. |
| [M2-E07](../epics/m2-e07-define-process-lifetime-identities.md): exact live identities | Complete clean identity and stale-result suites; protocol version 1 | `S/P` | Source plus macOS ARM64 artifact | Pass | Identities are not durable receipts. |
| [M2-E08](../epics/m2-e08-classify-console-events.md): classified Console events | Complete clean event suite; protocol version 1 | `S/P` | Source plus macOS ARM64 artifact | Pass | Sequence ownership stays with the session owner. |
| [M2-E09](../epics/m2-e09-project-jidoka-events.md): one canonical projection boundary | Commit `3b20fb7`; clean projection suite; [raw-path result](v0-2-closeout-session-plane.json) | `S/P` | Installed macOS ARM64 artifact | Pass | One approved raw ingress remains in the owner. |
| [M2-E10](../epics/m2-e10-define-renderer-neutral-session-state.md): renderer-neutral semantic state | Complete clean state and projection suites; snapshot schema version 1 | `S/P` | Source plus macOS ARM64 artifact | Pass | No live renderer value enters shared state. |
| [M2-E11](../epics/m2-e11-implement-semantic-reduction-and-replay.md): live and replay equivalence | Complete clean reducer and replay suites; [artifact recovery result](v0-2-closeout-session-plane.json) | `S/P` | Installed macOS ARM64 artifact | Pass | Recovery is process-lifetime only. |
| [M2-E12](../epics/m2-e12-add-session-supervision-topology.md): supervised session topology | Complete clean application, supervisor, and server suites; OTP 29 | `S/P` | Source plus macOS ARM64 artifact | Pass | One live owner per session. |
| [M2-E13](../epics/m2-e13-make-session-server-the-owner.md): session owner and event order | Complete clean server suite; [artifact lifecycle result](v0-2-closeout-session-plane.json) | `S/P` | Installed macOS ARM64 artifact | Pass | Stale and foreign results fail closed. |
| [M2-E14](../epics/m2-e14-run-model-and-tool-work-in-workers.md): supervised workers outside owner | Complete clean server and worker suites; artifact failure and cleanup result | `S/P` | Installed macOS ARM64 artifact | Pass | No orphan owned worker was found. |
| [M2-E15](../epics/m2-e15-admit-process-lifetime-input.md): input admission before advisory | Complete clean input and server suites; protocol version 1 | `S/P` | Source plus macOS ARM64 artifact | Pass | Input can be lost on application crash. |
| [M2-E16](../epics/m2-e16-separate-steering-and-follow-up.md): separate steering and follow-up queues | Complete clean queue and server suites; protocol version 1 | `S/P` | Source plus macOS ARM64 artifact | Pass | No durable queue claim. |
| [M2-E17](../epics/m2-e17-bound-client-delivery.md): bounded client delivery | Commit `cea221b`; [artifact receiver result](v0-2-closeout-session-plane.json), schema 1 | `S/P` | Installed macOS ARM64 artifact | Pass | One 62-byte message; zero queued bytes after gap; 16-event, 7,461-byte in-flight batch. |
| [M2-E18](../epics/m2-e18-recover-clients-from-gaps.md): exact gap recovery | Commit `ba61e06`; [artifact recovery result](v0-2-closeout-session-plane.json), schema 1 | `S/P` | Installed macOS ARM64 artifact | Pass | Snapshot 1, suffix 2-3, exact owner equality, then incremental 4. |
| [M2-E19](../epics/m2-e19-add-exact-worker-drain.md): exact worker drain | Complete clean drain suite and artifact parent-first drain result | `S/P` | Installed macOS ARM64 artifact | Pass | Drain waits for the owned child. |
| [M2-E20](../epics/m2-e20-add-two-stage-cancellation.md): cancellation and cleanup | Complete clean cancellation suite and artifact cancellation result | `S/P` | Installed macOS ARM64 artifact | Pass | Cancellation leaves no active request. |
| [M2-E21](../epics/m2-e21-build-command-and-client-registry.md): command and client registry | Complete clean catalog suite and packaged command acceptance | `S/P` | macOS ARM64, all channels | Pass | Registry is the declared command source. |
| [M2-E22](../epics/m2-e22-return-typed-command-effects.md): typed effects | Complete clean effect and command suites; protocol version 1 | `S/P` | Source plus macOS ARM64 artifact | Pass | Effect data does not grant authority. |
| [M2-E23](../epics/m2-e23-separate-model-and-view-results.md): model content and view detail split | Complete clean result and projection suites; parity fixture version 1 | `S/P` | Installed macOS ARM64 artifact | Pass | Renderer detail is not semantic ownership. |
| [M2-E24](../epics/m2-e24-complete-permission-lifecycle.md): permission lifecycle | Complete clean permission suite; seven-event parity ledger | `S/P` | Installed macOS ARM64 artifact | Pass | Permission decision is `approved` in the fixed offline fixture. |
| [M2-E25](../epics/m2-e25-define-extension-and-hook-contracts.md): extension and hook contracts | Complete clean hook, extension, and failure-policy suites | `S/P` | Source plus macOS ARM64 artifact | Pass | Extension loading stays outside M2. |
| [M2-E26](../epics/m2-e26-establish-session-client-contract.md): renderer-neutral client contract | Commit `918c71e`; complete contract suite; artifact parity fixture version 1 | `S/P` | Installed macOS ARM64 artifact | Pass | Contract remains process-lifetime. |
| [M2-E27](../epics/m2-e27-migrate-tui-session-client.md): TUI client migration | Commit `1b00ef4`; artifact TUI parity and lifecycle results | `S/P` | Installed macOS ARM64 artifact | Pass | Renderer state stays client-local. |
| [M2-E28](../epics/m2-e28-migrate-automation-session-client.md): automation client migration | Commit `b7f5f6a`; artifact automation parity and public replay paths | `S/P` | Installed macOS ARM64 artifact | Pass | Backward-compatible offline `run` and `eval` pass. |
| [M2-E29](../epics/m2-e29-migrate-text-session-client.md): text client migration | Commit `794a997`; artifact text parity fixture version 1 | `S/P` | Installed macOS ARM64 artifact | Pass | Same semantic ledger and side effects. |
| [M2-E30](../epics/m2-e30-migrate-json-session-client.md): JSON client migration | Commit `1a61e31`; artifact JSON parity fixture version 1 | `S/P` | Installed macOS ARM64 artifact | Pass | Same semantic ledger and side effects. |
| [M2-E31](../epics/m2-e31-prove-current-client-parity.md): production client parity | Commit `7122cff`; [artifact parity result](v0-2-closeout-session-plane.json), fixture version 1 | `S/P` | Installed macOS ARM64 artifact | Pass | Fingerprint `sha256:075e0de8df90d5e56790a2b70e0a09099f142d07a2f3a6cd367cb9803f1252d8`. |
| [M2-E32](../epics/m2-e32-remove-old-tui-session-path.md): old path removed | Commit `02009c0`; [artifact raw-path result](v0-2-closeout-session-plane.json); deliberate fixtures | `S/P` | Installed macOS ARM64 artifact | Pass | Only `Session.Server.handle_info/2` accepts raw Jidoka ingress. |
| [M2-E36](../epics/m2-e36-requalify-v0-2-after-closeout.md): exact final candidate | [Candidate](v0-2-closeout-candidate.md), acceptance, matrix, provenance, and session-plane records | `S/P` | macOS ARM64, archive, Homebrew, npm | Pass | Publication, signing, and notarization are skipped. |

## Repair Review

The post-closeout proof found three defects before the final candidate. Each
defect has a separate repair epic and commit. The final payload includes all
three repairs.

| Repair | Commit | Final-candidate review |
| --- | --- | --- |
| [M2-E38 private acceptance home](release-acceptance-home.md) | `cc09da1` | Acceptance uses isolated `JIDO_HOME`; pass. |
| [M2-E39 paint-first packaged TUI](paint-first-packaged-tui.md) | `35c2a81` | First frame 241 ms warm median and before readiness; pass. |
| [M2-E40 npm native root](npm-native-root.md) | `e7ee26e` | npm install, first run, update, and remove; pass. |

No open critical defect invalidates the source-quality claim. The rejected
pre-repair candidate and its checksum are not final evidence.

## Common Release Gate Review

| Common gate | Audited evidence | Result |
| --- | --- | --- |
| Clean production candidate | Clean source and exact provenance | Pass |
| Install, start, update, and remove every claimed cell | Three-cell channel matrix | Pass |
| Earlier workflows and fixtures | 686 passed, 1 skipped; two-way Jidoka gate; offline replay and coding workflow | Pass |
| Milestone outcome through artifact | Installed private-runtime session-plane proof | Pass |
| Runnable quick start and complete workflow | Candidate quick start and provider-free offline suite | Pass |
| Failure, cancellation, recovery, and cleanup | Artifact session-plane result | Pass |
| Support, limits, security, and repair | Candidate record and three repair records | Pass |
| Deterministic, package, dependency, secret, and release checks | Precommit, coverage, metadata, inventory, notices, and artifact acceptance | Pass |
| No critical defect | Repair review and final passing payload | Pass |
| Roadmap, epics, Beadwork, proof, and quality links | This audit and proof index | Pass |

The automated acceptance record has ten passing artifact gates. The complete
clean suite has 686 passes, one declared skip, and 90.2% line coverage.

## Milestone 2 Exit-Gate Review

| Exit claim | Audited result |
| --- | --- |
| Ordered Jidoka stream and request cleanup | Pass through the pinned two-way compatibility gate. |
| Live reduction and semantic replay agree | Pass in the clean suite and artifact recovery result. |
| Duplicate and invalid-order events fail safely | Pass in the final projection and event suites. |
| No current client consumes raw Jidoka or runtime output | Pass in the final artifact raw-path guard. |
| TUI detach and reattach preserve the session | Pass with a new attachment and a live owner. |
| TUI, automation, text, and JSON use one client contract | Pass with one seven-event ledger and one fingerprint. |
| Automation contracts stay compatible | Public offline `run` and `eval` pass without a live provider. |
| Old TUI path is deleted | Pass; one approved owner ingress remains. |
| Packaged TUI paints and becomes ready within limits | Pass: 241 ms first frame and 1,018.5 ms readiness warm medians. |
| npm keeps the native target root | Pass in all four lifecycle stages. |
| Stale, repeated, and foreign results cannot resolve current work | Pass in the clean contract and server suites. |
| Stopped receiver stays bounded and recovers | Pass: one 62-byte advisory and exact snapshot-plus-suffix recovery. |
| Every client-bound live message uses bounded incremental delivery | Pass; ordinary sequences are `[1, 2]`, then `[3]`, with no snapshot polling. |
| Client or worker failure does not corrupt the session | Pass in typed failure, drain, cancellation, and cleanup results. |
| Hook failures follow their declared policy | Pass in the complete clean suite. |
| Application-crash loss limit is explicit | Pass in the candidate and this audit. |
| E36 qualifies and E37 audits the exact final source | Pass. |
| Common milestone release gate | Pass. |

## Support and Known Limits

The approved support cell is macOS ARM64. The tested channels are direct
archive, Homebrew, and npm. Each local channel wrapper reports the same native
payload identity. No wrapper was published.

The following limits remain explicit:

- Accepted input can be lost if the application crashes before Milestone 3.
- Recovery and delivery receipts are process-lifetime only.
- There is no application-restart recovery, durable resume, or durable input
  receipt.
- Linux, Windows, and macOS x64 are not in the support claim.
- The automated PTY and terminal checks pass. The separate human TUI checklist
  remains pending.
- The native archive is not release-signed or notarized. Its local ephemeral
  payload seal is test evidence only.

The pending human TUI checklist and absent signing are not critical defects for
this source-quality, no-publication milestone. They cannot be used as public
release evidence.

## Historical and Publication Review

M2-E33 and M2-E34 are historical evidence for a source before the closeout
commits. They are superseded and do not satisfy a final-source row in this
audit. They remain unchanged.

M2-E35 remains the closed no-publication decision. This audit found no local
v0.2 tag and no publication record. No GitHub release, archive upload, Homebrew
publication, or npm publication was made as part of M2-E36 or M2-E37.

Approval does not authorize publication. A future maintainer decision must use
a separate protected workflow and new publication evidence.

## Approved Milestone 3 Baseline

Milestone 3 planning and implementation must use this exact baseline:

| Baseline field | Approved value |
| --- | --- |
| Console source | `e7ee26e70c571c9af50ba9840d17f3524ba5e7e0` |
| Console tree | `7266e79495db8bf6e59277613571a381c9d14f6f` |
| Roadmap | `1.3.4` |
| Jidoka source | `29246d0a762fe1b17f4250e4f5c98c9f3f6d8419` |
| Native payload | `65cbb458061e72bd38ac2efe96bef5de6677a9b649d90a12841a8b40303a7e35` |
| Candidate evidence | `0e0ed85228b592cdde12bc0a46a319406a63813c` |

The E36 evidence commit and this audit commit are documentation inputs. They
are not replacement product baselines. The preloaded Milestone 3 graph must be
validated against the table above before implementation starts.

## Final Finding

All required final-source claims use one source and one native payload. Every
claimed platform-channel cell passes. The common release gate and Milestone 2
exit gate pass. The stopped-receiver, incremental-output, recovery, parity, and
raw-path results pass. The known limits are explicit. No critical defect
invalidates the claim. Publication stays skipped.

The final decision is `approved`.
