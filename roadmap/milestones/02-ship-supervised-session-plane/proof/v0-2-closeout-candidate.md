# v0.2 Closeout Candidate

Beadwork: `jido_console-m2e36`

Decision: `pass`

This record qualifies one clean, post-closeout Milestone 2 candidate. It does
not publish a release. The package reports version `0.1.0`. The roadmap quality
target is v0.2. This source-quality decision does not change the package
version.

## Frozen Identity

| Field | Frozen value |
| --- | --- |
| Console source commit | `e7ee26e70c571c9af50ba9840d17f3524ba5e7e0` |
| Console source tree | `7266e79495db8bf6e59277613571a381c9d14f6f` |
| Console source state | Clean |
| Roadmap version | `1.3.4` |
| Jidoka commit | `29246d0a762fe1b17f4250e4f5c98c9f3f6d8419` |
| Jidoka tree | `f86eaf57bdea8e347acd5e0aca35c21ebc08850d` |
| Jidoka package version | `0.9.1` |
| `mix.lock` SHA-256 | `0a27a559158aee74633008987d5c9cfc68502778476fb3a65dd33fb0f1056f80` |
| Toolchain SHA-256 | `6cc0316a440c6aae9d884d2d704ff970f8455c34b054103ed9e64056a2c5caf6` |
| Platform | macOS `26.5.2` build `25F84`, ARM64 |
| Erlang/OTP | `29`, ERTS `17.0.2` |
| Elixir | `1.20.2` |
| Mix | `1.20.2` |
| Build tool | `mix jido.release` |
| Build time | `2026-08-17T18:16:52Z` |

The CycloneDX SBOM in the candidate output records the complete OTP, Elixir,
Hex, and source dependency set. The frozen provenance is stored in
[`v0-2-closeout-provenance.json`](v0-2-closeout-provenance.json).

## Native Payload

| Field | Value |
| --- | --- |
| Artifact | `jido-0.1.0-darwin-arm64.tar.gz` |
| Package version | `0.1.0` |
| Target | `darwin-arm64` |
| Size | `78,680,507` bytes |
| SHA-256 | `65cbb458061e72bd38ac2efe96bef5de6677a9b649d90a12841a8b40303a7e35` |
| Build source | Clean commit `e7ee26e70c571c9af50ba9840d17f3524ba5e7e0` |

The archive and its full `release.json`, `sbom.json`, `provenance.json`, and
checksum set are in the normal ignored `dist/m2e36-closeout/` release output.
The final channel matrix uses the same archive checksum in each channel.

The local payload seal used a temporary Ed25519 key only to test payload
integrity and the three channel owners. It is not a release signature. The
archive is not signed or notarized.

## Clean Source Gate

`mix jido.release` ran in a new clean checkout with Jidoka at the frozen commit.
It returned success.

| Gate | Result |
| --- | --- |
| Locked dependency check | Pass |
| Formatting, compile, Credo, Dialyzer, Doctor, and precommit checks | Pass |
| Complete test suite | 686 passed, 1 skipped |
| Line coverage | 90.2% |
| Console-to-Jidoka and Jidoka-to-Console compatibility | Pass |
| Production artifact build | Pass |
| Installed-artifact acceptance | Pass |

The skipped test is the declared existing skip in the complete suite. The
clean rerun had no failure.

## Installed-Artifact Acceptance

The stable record is
[`v0-2-closeout-acceptance.json`](v0-2-closeout-acceptance.json). The acceptance
runner extracted the exact archive in a path with spaces and non-ASCII text. It
used a private `JIDO_HOME`, removed the operator `HOME`, and restricted `PATH`
to `/usr/bin:/bin`.

All ten artifact gates passed:

- Archive checksum, metadata contract, and internal file inventory.
- Private bundled runtime, notices, SBOM, and provenance.
- Startup performance and packaged command behavior.
- Paint-first TUI behavior and terminal cleanup.
- Read-only installation.
- External coding workflow with a writable workspace outside the package.

The provider-free replay matched, the bundled native library loaded, and no
live provider was called. The coding workflow changed only
`lib/rate_limiter.ex`, used the private runtime for `mix test`, and passed its
repository oracle. The installed package stayed read-only.

The 20 warm-run startup profile passed:

| Command or state | Warm median | Warm p95 | Limit |
| --- | ---: | ---: | ---: |
| `--help` | 210.447 ms | 226.355 ms | 500 ms |
| `--version` | 222.062 ms | 238.755 ms | 500 ms |
| First TUI frame | 241 ms | 263 ms | 500 ms |
| Runtime ready | 1,018.5 ms | 1,068 ms | 1,250 ms |

The first frame preceded runtime readiness. One input was queued during slow
startup. A startup failure stayed visible. `Ctrl-C` completed terminal cleanup
without the Erlang break menu.

## Platform and Channel Matrix

The stable record is
[`v0-2-closeout-channel-matrix.json`](v0-2-closeout-channel-matrix.json). Each
required cell passed install, first run, update, and remove. Each cell used the
same native payload checksum.

| Platform | Channel | Install | First run | Update | Remove |
| --- | --- | --- | --- | --- | --- |
| macOS ARM64 | Direct archive | Pass | Pass | Pass | Pass |
| macOS ARM64 | Homebrew formula | Pass | Pass | Pass | Pass |
| macOS ARM64 | npm package | Pass | Pass | Pass | Pass |

The npm command ran the native launcher in the target package. It did not
compile code or download a runtime. Linux, Windows, and macOS x64 are not in
the support claim and were not tested.

## Supervised Session Plane Through the Artifact

The proof used this installed private runtime:

`<archive-root>/libexec/bin/jido eval <proof-runner>`

The public `<archive-root>/bin/jido` command does not expose arbitrary runtime
evaluation. The private command was used only as an artifact diagnostic. Every
listed production module loaded from the extracted archive, not from the
development build.

The reproducible runner is
[`v0-2-closeout-artifact-proof.exs`](v0-2-closeout-artifact-proof.exs). Its
SHA-256 is
`88c1923d62b2c2d9167ea715187390fd211a64e6b69ef441d506bed7f6d055ce`.
The stable result is
[`v0-2-closeout-session-plane.json`](v0-2-closeout-session-plane.json).

### Receiver and copied-payload bounds

One real client process attached to one real session owner and then stopped
reading. The owner completed 100 operations and produced sequence 200. The
condition remained for 5,100 ms, which is longer than the 5,000 ms
acknowledgement timeout.

| Measurement | Result | Limit |
| --- | ---: | ---: |
| Receiver mailbox | 1 message | 1 advisory |
| Copied message count | 1 | 1 advisory |
| Copied message size | 62 bytes | 4,096 bytes |
| Server queued items after gap | 0 | 32 |
| Server queued bytes after gap | 0 | 1,048,576 bytes |
| Server in-flight bytes after gap | 0 | 262,144 bytes |
| Separate in-flight batch | 16 events, 7,461 bytes | 16 events, 262,144 bytes |

A separate 10,000-update delivery stress ended in one bounded gap with zero
queued items and zero queued or in-flight bytes. The exact in-flight batch
changed to an `acknowledgement_timeout` gap and released its copied bytes.

### Recovery and ordinary output

A real acknowledgement gap started at owner sequence 1. Recovery returned one
snapshot at sequence 1 and one contiguous suffix with sequences 2 and 3. The
restored client state equaled the owner state at sequence 3. The exact receipt
ended at sequence 3. Normal delivery then resumed with sequence 4.

An independent ordinary-output trace returned two `output_batch` envelopes
with sequences `[1, 2]` and `[3]`. It did not use a repeated full snapshot.

### Lifecycle, parity, and raw-path removal

- Detach kept the session owner alive. Reattach created a new attachment.
- A start failure returned the typed `artifact_start_failure` result.
- Cancellation returned `cancelled` and left no active request.
- A parent-first drain stayed incomplete until its child was collected. The
  exact drain then completed.
- Final cleanup stopped the session server.
- TUI, automation, text, and JSON produced the same seven-event semantic
  ledger and the same side effects.
- The normalized parity fingerprint stayed
  `sha256:075e0de8df90d5e56790a2b70e0a09099f142d07a2f3a6cd367cb9803f1252d8`.
- The public TUI parity entry, public `run`, and public `eval` replay paths
  passed without a live provider.
- The M2-E32 syntax guard found no client or legacy-owner bypass. It found one
  approved raw Jidoka ingress: `Session.Server.handle_info/2`.
- Both deliberate raw-path fixtures failed closed.

The fixed parity fixture is version 1. Its source SHA-256 is
`245e641509dc3ff35079e7ec2f38bb95cf0c845472256d6c9d27310e45cadbf3`.
The replay fixture SHA-256 is
`8b2556dfd59d62bcf3007a6deee3c1596e56e2e877b7052a7adcf46319ea52c4`.

## Runnable Candidate Quick Start

These commands use the local candidate output. They do not install or publish
it system-wide.

```sh
candidate_root=$(mktemp -d /tmp/jido-v0-2-candidate.XXXXXX)
mkdir -p "$candidate_root/home"
tar -xzf dist/m2e36-closeout/jido-0.1.0-darwin-arm64.tar.gz -C "$candidate_root"
candidate_package="$candidate_root/jido-0.1.0-darwin-arm64"
JIDO_HOME="$candidate_root/home" "$candidate_package/bin/jido" --version
JIDO_HOME="$candidate_root/home" "$candidate_package/bin/jido" --help
JIDO_HOME="$candidate_root/home" "$candidate_package/bin/jido" eval \
  "$candidate_package/share/jido/offline/suite.yml"
```

The expected version output is `jido 0.1.0`. The final command is a complete,
provider-free workflow. Its case result must report a matched replay. A live
interactive session can incur provider cost and is outside this offline quick
start.

## Support, Security, and Repair

The support claim stays macOS ARM64 through the direct archive, Homebrew, and
npm packages that wrap one payload. This candidate does not add a platform,
provider, model, client, or execution claim. The repository README still says
that there is no stable public release or installation contract.

Security checks used restricted execution, a read-only package, a separate
writable workspace, a private product home, blocked system Erlang and Elixir
tools, no live provider, and the final raw-client boundary guard. Trusted
workspace mode is still not a sandbox.

Three repair records explain the path used before this candidate:

- [`release-acceptance-home.md`](release-acceptance-home.md) isolates the
  installed-artifact product home.
- [`paint-first-packaged-tui.md`](paint-first-packaged-tui.md) restores first
  paint before slow startup and keeps startup failures visible.
- [`npm-native-root.md`](npm-native-root.md) preserves the target-package root
  in the npm launcher.

If a final identity or behavior changes, discard this candidate and run M2-E36
again with a new checksum. Do not edit this record to point at mixed evidence.

## Known Limits and Publication State

- Recovery and delivery receipts are process-lifetime only.
- Accepted input can be lost if the application crashes before Milestone 3.
- There is no application-restart recovery, durable resume, or durable input
  receipt.
- The automated PTY and terminal gates passed. The separate human TUI checklist
  in `manual-tui.json` remains pending.
- Linux, Windows, and macOS x64 are not tested or supported by this candidate.
- The archive is not signed or notarized.

No tag, GitHub release, archive upload, Homebrew publication, or npm
publication was created. The temporary local payload seal does not change this
state. Publication remains intentionally skipped.

## Handoff

M2-E37 must audit this exact source commit, native checksum, stable evidence,
support claim, and known-limit statement. M2-E33 and M2-E34 remain historical
records for an earlier source and cannot qualify this candidate.
