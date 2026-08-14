# Jido Console Roadmap

Status: **proposed**

Jido Console will grow from the current terminal and automation client into a
local, durable, multi-client control plane for coding agents. Each phase must
pass its exit gate before dependent work starts. Each phase must leave the
`jido` command in a working state.

| Phase | Result | Release point |
| --- | --- | --- |
| 0. Preserve the baseline | Stable tests, fixtures, and release evidence | Baseline |
| 1. Establish Jido Console | New identity, safe provider access, stable local paths, and tested installation | v0.1 |
| 2. Add the semantic core | Renderer-neutral session state | Internal milestone |
| 3. Supervise sessions | Sessions that clients can attach to | v0.2 |
| 4. Convert surfaces to clients | One protocol for terminal, automation, text, and JSON | Internal milestone |
| 5. Add durable resume | Restart-safe local sessions | v0.3 |
| 6. Add the shared workbench | Web views and declared shared resources | v0.4 |
| 7. Separate brains from hands | Controlled local, isolated, and remote execution | v0.5 |
| 8. Control live extension | Reviewed changes, recovery, and rollback | Later release |

## Rules

- Jidoka is the only agent runtime.
- Jido Console has one semantic session model.
- A client is a projection. It is not a source of truth.
- Automation contracts stay versioned and stable.
- Durable work is accepted before execution starts.
- Credentials do not enter configuration, events, logs, traces, or artifacts.
- Untrusted work uses an isolation boundary. An OTP node is not a sandbox.
- Terminal, Homebrew, npm, and archive packages use the same tested release.
- A later feature does not block an earlier useful release.

The roadmap will change through public discussion. Implementation work starts
only after a maintainer marks a scoped roadmap item as ready. To implement an
item, use the [12-hour ownership policy](ROADMAP_OWNERSHIP.md).
