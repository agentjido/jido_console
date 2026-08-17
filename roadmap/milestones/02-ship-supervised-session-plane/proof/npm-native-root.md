# npm native package root

Beadwork: `jido_console-ih5`

## Result

Passed. The npm target package keeps the complete native archive layout. The
entry package contains a small launcher that resolves the npm command link and
then runs the native launcher from the target package. The native launcher now
finds `libexec` below its unchanged package root.

The npm entry and target manifests still contain no install scripts. The
repair does not compile code, download a runtime, or publish a package.

## Reproduction

The first channel run used candidate checksum
`c65c63224ddfd6f2ae4e80d625d5281c17553ddbc26271ebb8c0d2e72782cf06`.
Archive and Homebrew passed. npm installed the same payload, but its copied
native launcher searched for `libexec` at the npm prefix root and failed its
first run.

After the repair, the same payload checksum passed archive, Homebrew, and npm.
Each channel passed install, first run, update, and removal. The cross-channel
identity comparison also passed.

## Checks

- Focused archive, Homebrew, npm, and matrix suite: 12 passed.
- Complete test suite: 686 passed; 1 skipped.
- Common precommit gate: passed.
- npm global, local, exec, and npx flows: passed.
- Real-payload archive lifecycle: passed.
- Real-payload Homebrew lifecycle: passed.
- Real-payload npm lifecycle: passed.
- Cross-channel payload identity comparison: passed.
- Publication: not done.

One first complete-suite run observed an unrelated worker-monitor race as
`:noproc` instead of `:normal`. The exact test passed on retry, and the next
complete-suite run passed.
