# Jido Console

> [!WARNING]
> Jido Console is in active development. It is not ready for use. There is no
> stable release, installation path, API, or data format yet.

## Help Build Jido Console

Start with the [roadmap](ROADMAP.md) and the
[contribution guide](CONTRIBUTING.md). The roadmap is open for review. Each
ready epic maps to one pull request.

### Major Roadmap Items

- [ ] Preserve and publish the current baseline.
- [ ] Establish the Jido Console identity, local paths, and release channels.
- [ ] Add a renderer-neutral semantic session core.
- [ ] Add supervised sessions that clients can attach to.
- [ ] Move terminal, automation, text, and JSON to one client protocol.
- [ ] Add durable session resume and recovery.
- [ ] Add a shared web workbench and declared shared resources.
- [ ] Add controlled local, isolated, and remote execution.
- [ ] Add reviewed live extension, recovery, and rollback.

Read the [full roadmap](ROADMAP.md) for the order and architecture rules.

### Ways to Get Involved

- [Join the Jido Discord](https://jido.run/discord) to meet the community.
- [Start a Discussion](https://github.com/agentjido/jido_console/discussions/new/choose)
  to ask a question or propose an idea.
- Own a ready epic and its pull request. Read the
  [12-hour reservation policy](ROADMAP_OWNERSHIP.md) first.
- Give roadmap feedback in
  [Discussions](https://github.com/agentjido/jido_console/discussions).
- Test the current work and report failures in a
  [bug Discussion](https://github.com/agentjido/jido_console/discussions/new?category=q-a).

Jido Console collects no usage data or telemetry. A useful bug report includes
the operating system, architecture, OTP and Elixir versions, commit ID, exact
steps, expected result, actual result, and sanitized output. Add a small
reproduction when possible. Never include credentials.

## Jido, Jidoka, and Jido Console

| Project | Role |
| --- | --- |
| [Jido](https://github.com/agentjido/jido) | The Elixir framework and core building blocks for autonomous agents. |
| [Jidoka](https://github.com/agentjido/jidoka) | The runtime for agent sessions, execution, effects, cancellation, and recovery. |
| Jido Console | The user-facing control plane for terminal, automation, web, SSH, text, and JSON clients. |

Jidoka owns agent execution truth. Jido Console owns user-visible session truth.
A client presents session state. It does not own that state.

Jido Console is intended to run supported models, keep work alive, isolate
tools, show effects, compare results, and recover sessions without loss of
accepted work.

Licensed under Apache-2.0. See [LICENSE](LICENSE).
