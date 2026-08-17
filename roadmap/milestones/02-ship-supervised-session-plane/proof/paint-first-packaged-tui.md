# Paint-first packaged TUI

Beadwork: `jido_console-xou`

## Result

Passed. The interactive CLI no longer starts the complete application before
the terminal opens. The TUI draws its starting frame, starts the application,
attaches the session client, registers the interactive process, and then starts
the runtime. Trusted model policy identity and tier data supplies the initial
selection without an LLMDB metadata lookup.

Application, attach, registration, and runtime failures use the visible TUI
failure state. Cleanup stops the process record only after successful
registration, and cleanup errors cannot replace the original result.

## Installed-package measurements

A diagnostic production package used the private OTP runtime, an explicit
private `JIDO_HOME`, and no `HOME`. One cold run was removed before the warm
profile was evaluated.

- Warm first-frame samples: 239, 251, 235, 227, 212, 220, and 221 ms.
- Warm runtime-ready samples: 1,059, 1,084, 1,043, 987, 961, 994, and 982 ms.
- Required first-frame limit: less than 500 ms.
- Required runtime-ready limit: less than 1,250 ms.

The packaged success probe painted first, accepted one prompt during startup,
showed `prompt queued`, completed the prompt once, returned to idle, and closed
the terminal. The packaged failure probe painted first, showed the startup
failure, preserved the failure until Escape, and closed the terminal.

## Checks

- Focused CLI, TUI, selection, and release-entry suite: 55 passed.
- Complete test suite: 685 passed; 1 skipped.
- Common precommit gate: passed.
- Model metadata resolver before initial selection: not called.
- Successful packaged TUI probe: passed; one queued turn recorded.
- Failed packaged TUI probe: passed.
- `HOME` in the packaged probe environment: absent.
- Product version in the diagnostic package: `0.1.0`.
- Quality target: v0.2 source milestone; publication remains skipped.
