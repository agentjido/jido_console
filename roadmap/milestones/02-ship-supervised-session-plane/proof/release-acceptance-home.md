# Release acceptance home

Beadwork: `jido_console-zs5`

## Result

Passed. Installed-artifact acceptance now creates one private `JIDO_HOME`
below its temporary root. It gives that same path to startup measurements,
packaged commands, native and TUI probes, the read-only check, and the external
coding workflow. The clean child environment still has no `HOME` value.

## Reproduction

The first M2-E36 attempt stopped before runtime readiness. The installed
process reported that it could not find the user home because acceptance uses
`env -i` and did not provide `JIDO_HOME`.

After the repair, five installed TUI runs with `HOME` absent reached idle. The
observed first-frame times were 2,568, 2,437, 2,517, 2,471, and 2,480 ms. The
observed ready times were 2,848, 2,718, 2,785, 2,732, and 2,750 ms. These values
prove the home repair only. They do not pass the release performance limits.

The diagnostic acceptance run passed checksum, metadata, file inventory,
private runtime, notices, startup with diagnostic limits, and packaged-command
checks. It then exposed a separate eager-start and process-supervisor defect.
That defect is not part of this epic and blocks M2-E36 through a separate
repair epic.

## Checks

- Focused release-tooling suite: 10 passed.
- Compile with warnings as errors: passed.
- Acceptance home mode: `0700`.
- Operator home in child environment: absent.
- Product version in the diagnostic archive: `0.1.0`.
- Quality target: v0.2 source milestone; publication remains skipped.
